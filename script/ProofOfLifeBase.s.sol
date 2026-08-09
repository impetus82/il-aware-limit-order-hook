// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";

/// @title  SwapRouterBase — minimal unlock-callback swap router (mainnet, self-contained)
/// @dev    Drives a single pool swap and settles both currencies by sign. Used only to TRIGGER the
///         resting limit order (the hook self-executes the order inside afterSwap). Owner-gated.
contract SwapRouterBase is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) external {
        require(msg.sender == owner, "only owner");
        poolManager.unlock(abi.encode(key, msg.sender, zeroForOne, amountSpecified, sqrtPriceLimitX96));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        (PoolKey memory key, address payer, bool zeroForOne, int256 amountSpecified, uint160 limit) =
            abi.decode(data, (PoolKey, address, bool, int256, uint160));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            ""
        );
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return "";
    }

    /// @dev negative delta = router owes the pool (pull from payer, settle); positive = pool owes us (take).
    function _settle(Currency c, address payer, int128 d) internal {
        if (d < 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).transferFrom(payer, address(poolManager), uint256(uint128(-d)));
            poolManager.settle();
        } else if (d > 0) {
            poolManager.take(c, payer, uint256(uint128(d)));
        }
    }
}

/// @title  ProofOfLifeBase — end-to-end on-chain proof: place a SELL-WETH limit order, then trigger it.
/// @notice Step 1 of the proof-of-life. Places a small SELL-WETH order with a trigger just above spot,
///         then does a tiny USDC→WETH swap that pushes price across the trigger, so the hook fills the
///         order in afterSwap (no keeper). Prints the orderId + fill result. Claim is a separate step.
///
///   Base: currency0 = WETH, currency1 = USDC. SELL WETH (zeroForOne=true) triggers when price >= trigger.
///   Trigger encoding on Base is human USDC/WETH scaled to 1e6 (see docs/INTEGRATION.md).
///
///   Usage (from the worktree, env exported via `set -a && source .env && set +a`):
///     forge script script/ProofOfLifeBase.s.sol:ProofOfLifeBase --rpc-url https://mainnet.base.org --broadcast
contract ProofOfLifeBase is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce; // 2026-08-08 audit-hardened redeploy
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // Sizing (micro — fits the deployer's Base balances and the thin seed pool). Overridable via env.
    uint96 constant ORDER_WETH = 2e13; //   0.00002 WETH sold by the order
    uint256 constant SWAP_USDC = 3e3; //    0.003 USDC spent to nudge price across the trigger
    uint128 constant TRIGGER = 1_869_000_000; // 1869 USDC/WETH (just above the ~1866 spot)

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        address hook = vm.envOr("HOOK", HOOK);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        PoolId id = poolKey.toId();

        (, int24 tickBefore,,) = POOL_MANAGER.getSlot0(id);
        console2.log("=== ProofOfLifeBase ===");
        console2.log("Hook:", hook);
        console2.log("Spot tick before:", tickBefore);
        console2.log("WETH bal:", IERC20(WETH).balanceOf(me));
        console2.log("USDC bal:", IERC20(USDC).balanceOf(me));
        require(IERC20(WETH).balanceOf(me) >= ORDER_WETH, "need more WETH for the order");
        require(IERC20(USDC).balanceOf(me) >= SWAP_USDC, "need more USDC for the trigger swap");

        vm.startBroadcast(pk);

        // 1) Place a SELL-WETH order, trigger just above spot.
        IERC20(WETH).approve(hook, ORDER_WETH);
        uint256 orderId = ILAwareLimitOrderHook(hook).createLimitOrder(poolKey, true, ORDER_WETH, TRIGGER);
        console2.log("Order created, id:", orderId);

        // 2) Trigger it: a tiny USDC->WETH swap pushes price UP across the trigger; the hook fills the
        //    order inside afterSwap. zeroForOne=false sells USDC (currency1) for WETH (currency0).
        SwapRouterBase router = new SwapRouterBase(POOL_MANAGER);
        IERC20(USDC).approve(address(router), SWAP_USDC);
        router.swap(poolKey, false, -int256(SWAP_USDC), TickMath.MAX_SQRT_PRICE - 1);
        IERC20(USDC).approve(address(router), 0);

        vm.stopBroadcast();

        ILAwareLimitOrderHook.LimitOrder memory o = ILAwareLimitOrderHook(hook).getOrder(orderId);
        (, int24 tickAfter,,) = POOL_MANAGER.getSlot0(id);
        console2.log("\n=== RESULT ===");
        console2.log("Spot tick after:", tickAfter);
        console2.log("Order filled?", o.isFilled);
        console2.log("Order output (USDC, claimable):", uint256(o.amount1));
        console2.log("nextOrderId now:", ILAwareLimitOrderHook(hook).nextOrderId());
        console2.log("Next: depositToVault(%s) then claimOrder(%s, poolKey)", orderId, orderId);
    }
}
