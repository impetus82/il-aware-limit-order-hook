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

/// @title SwapRouterUnichain - On-chain router for PoolManager swaps on Unichain
/// @dev Uses TransientStateLibrary to read real outstanding deltas
///      after afterSwap hook may have modified them.
///      Settlement order: ALL negative deltas first, then ALL positive deltas.
///
///      Unichain token sort: currency0 = USDC, currency1 = WETH
///      To trigger "Sell WETH" limit orders, we need WETH price to rise.
///      We buy WETH with USDC: zeroForOne = true (send currency0, receive currency1).
///      When zeroForOne=true, sqrtPrice moves DOWN, but since currency0=USDC/currency1=WETH,
///      this means WETH becomes MORE expensive in USDC terms (price UP).
contract SwapRouterUnichain is IUnlockCallback {
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

        // ═══════════════════════════════════════════════════════════
        // SWAP: Buy WETH (currency1) with USDC (currency0)
        //
        // zeroForOne = true → we send currency0 (USDC), receive currency1 (WETH)
        // amountSpecified < 0 → exact input (we specify how much USDC to spend)
        // sqrtPriceLimitX96 = MIN + 1 → allow price to move as far as needed
        //
        // In Uniswap V4 with inverted pair (USDC/WETH):
        //   zeroForOne=true moves sqrtPrice DOWN
        //   sqrtPrice DOWN means currency1 (WETH) costs MORE in currency0 (USDC)
        //   = WETH price going UP = what we want to trigger "Sell WETH" orders
        // ═══════════════════════════════════════════════════════════
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        poolManager.swap(poolKey, swapParams, "");

        // ═══════════════════════════════════════════════════════════
        // Read REAL outstanding deltas from transient storage.
        // afterSwap hook may have modified them (order execution).
        // ═══════════════════════════════════════════════════════════

        int256 delta0 = poolManager.currencyDelta(address(this), poolKey.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), poolKey.currency1);

        // ═══════════════════════════════════════════════════════════
        // SETTLE ALL NEGATIVE DELTAS FIRST (we owe tokens to pool)
        // Must sync -> transfer -> settle for each negative delta
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

    /// @dev sync -> transferFrom(payer -> PM) -> settle
    function _settleNegative(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }
}

/// @title TriggerSwapUnichain - Execute a micro-swap on Unichain to trigger limit order fills
/// @notice Deploys a SwapRouterUnichain on-chain, then swaps USDC -> WETH
/// @dev
///   Unichain: currency0 = USDC (0x078d...), currency1 = WETH (0x4200...)
///
///   Target: Trigger "Sell WETH" limit orders.
///   "Sell WETH" order on Unichain = sell currency1 for currency0, zeroForOne=false in the order.
///   To fill this order, WETH price must rise above triggerPrice.
///   Our swap buys WETH with USDC (zeroForOne=true), pushing WETH price up.
///   afterSwap hook checks price, finds eligible orders, executes them.
///
///   Usage:
///     source .env
///     forge script script/TriggerSwapUnichain.s.sol:TriggerSwapUnichain \
///       --rpc-url https://mainnet.unichain.org --broadcast \
///       --with-gas-price 100000000 -vvvv
contract TriggerSwapUnichain is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x1F98400000000000000000000000000000000004);

    // Unichain: USDC = currency0, WETH = currency1
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant HOOK = 0x9138F699F5F5AB19ed8271c3B143B229781A8040;

    uint24 constant POOL_FEE = 0; // Dynamic fee via hook
    int24 constant TICK_SPACING = 60;

    // 0.5 USDC — micro swap to push WETH price up
    uint256 constant SWAP_AMOUNT_USDC = 5e5;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Trigger Swap on Unichain USDC/WETH ===");
        console2.log("Deployer:", deployer);

        // Unichain: currency0 = USDC, currency1 = WETH
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
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
        require(usdcBal >= SWAP_AMOUNT_USDC, "Need at least 0.5 USDC");

        vm.startBroadcast(deployerPk);

        SwapRouterUnichain router = new SwapRouterUnichain(POOL_MANAGER);
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