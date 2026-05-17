// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title SwapRouter - On-chain router for PoolManager swaps
/// @dev Uses TransientStateLibrary to read real outstanding deltas
///      after afterSwap hook may have modified them.
///      Settlement order: ALL negative deltas first, then ALL positive deltas.
contract SwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable owner;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    function executeSwap(PoolKey calldata poolKey, uint256 amountIn) external {
        require(msg.sender == owner, "Only owner");
        bytes memory callbackData = abi.encode(poolKey, msg.sender, amountIn);
        poolManager.unlock(callbackData);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        (PoolKey memory poolKey, address payer, uint256 amountIn) =
            abi.decode(data, (PoolKey, address, uint256));

        // Swap: sell USDC (token1) for WETH (token0)
        // zeroForOne = false → buying token0 (WETH) with token1 (USDC)
        // amountSpecified < 0 → exact input
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        poolManager.swap(poolKey, swapParams, "");

        // ═══════════════════════════════════════════════════════════
        // Read REAL outstanding deltas from transient storage.
        // afterSwap hook may have modified them.
        // ═══════════════════════════════════════════════════════════

        int256 delta0 = poolManager.currencyDelta(address(this), poolKey.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), poolKey.currency1);

        // ═══════════════════════════════════════════════════════════
        // SETTLE ALL NEGATIVE DELTAS FIRST (we owe tokens to pool)
        // Must sync → transfer → settle for each negative delta
        // ═══════════════════════════════════════════════════════════

        if (delta0 < 0) {
            _settleNegative(poolKey.currency0, payer, uint256(-delta0));
        }
        if (delta1 < 0) {
            _settleNegative(poolKey.currency1, payer, uint256(-delta1));
        }

        // ═══════════════════════════════════════════════════════════
        // TAKE ALL POSITIVE DELTAS (pool owes tokens to us)
        // ═══════════════════════════════════════════════════════════

        if (delta0 > 0) {
            poolManager.take(poolKey.currency0, payer, uint256(delta0));
        }
        if (delta1 > 0) {
            poolManager.take(poolKey.currency1, payer, uint256(delta1));
        }

        return "";
    }

    /// @dev sync → transferFrom(payer → PM) → settle
    function _settleNegative(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }
}

/// @title TriggerSwapBase - Execute a micro-swap on Base to trigger limit order fills
/// @notice Deploys a SwapRouter on-chain, then swaps USDC → WETH
/// @dev
///   Order #1: Sell 0.0001 WETH @ 3500 USDC/WETH (zeroForOne=true)
///   afterSwap hook checks price and fills eligible orders automatically.
///
///   Usage:
///     source .env
///     forge script script/TriggerSwapBase.s.sol:TriggerSwapBase \
///       --rpc-url $BASE_RPC_URL --broadcast \
///       --with-gas-price 100000000 -vvvv
contract TriggerSwapBase is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x45d971BdE51dd5E109036aB70a4E0b0eD2Dc4040;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    uint256 constant SWAP_AMOUNT_USDC = 5e5; // 1 USDC

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Trigger Swap on Base WETH/USDC ===");
        console2.log("Deployer:", deployer);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceBefore, int24 tickBefore, , ) = POOL_MANAGER.getSlot0(poolId);
        uint128 liquidity = POOL_MANAGER.getLiquidity(poolId);

        console2.log("Current sqrtPriceX96:", uint256(sqrtPriceBefore));
        console2.log("Current tick:", tickBefore);
        console2.log("Liquidity:", uint256(liquidity));
        require(liquidity > 0, "Pool has 0 liquidity!");

        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        uint256 wethBal = IERC20(WETH).balanceOf(deployer);
        console2.log("USDC balance:", usdcBal);
        console2.log("WETH balance:", wethBal);
        require(usdcBal >= SWAP_AMOUNT_USDC, "Need at least 1 USDC");

        vm.startBroadcast(deployerPk);

        SwapRouter router = new SwapRouter(POOL_MANAGER);
        console2.log("SwapRouter deployed at:", address(router));

        // Approve USDC + WETH for router (transferFrom in callback)
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);

        router.executeSwap(poolKey, SWAP_AMOUNT_USDC);

        vm.stopBroadcast();

        (uint160 sqrtPriceAfter, int24 tickAfter, , ) = POOL_MANAGER.getSlot0(poolId);
        console2.log("\n=== SWAP EXECUTED ===");
        console2.log("sqrtPriceX96 after:", uint256(sqrtPriceAfter));
        console2.log("tick after:", tickAfter);
    }
}