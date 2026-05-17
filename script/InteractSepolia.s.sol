// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";

/// @title InteractSepolia — Live interaction with ILAwareLimitOrderHook on Sepolia
/// @author Yuri (Crypto Side Hustle 2026)
/// @dev Phase 3.13: Diagnostics, E2E debugging, pool state analysis.
///
///   Usage (pick one action at a time):
///
///   # Action 1: Create a limit order
///   forge script script/InteractSepolia.s.sol:CreateOrder \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   # Action 2: Execute a swap (trigger order fills)
///   forge script script/InteractSepolia.s.sol:ExecuteSwap \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --slow --with-gas-price 5000000000 -vvvv
///
///   # Action 3: Cancel an order
///   ORDER_ID=0 forge script script/InteractSepolia.s.sol:CancelOrder \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   # Action 4: Read order statuses
///   forge script script/InteractSepolia.s.sol:ReadStatus \
///     --rpc-url $SEPOLIA_RPC_URL -vvvv
///
///   # Action 5: Diagnose pool state (tick, price, liquidity, linked list)
///   forge script script/InteractSepolia.s.sol:ReadPoolState \
///     --rpc-url $SEPOLIA_RPC_URL -vvvv
///
///   Prerequisites:
///   - SetupSepolia.s.sol already executed (tokens deployed, pool initialized, liquidity added)
///   - .env configured with SEPOLIA_RPC_URL, PRIVATE_KEY

// ============================================================
//  SHARED CONFIGURATION
// ============================================================
abstract contract SepoliaConfig is Script {
    // --- Phase 3.15 deployed addresses ---
    address constant HOOK = 0x43BF7DA3d2e26D295a8965109505767e93B24040;
    address constant TOKEN0 = 0x5367BdE916282818fa3EE2c27ecbC79672D364ed; // TTA (sorted)
    address constant TOKEN1 = 0xfa6b4B169D5BC4d12bD07B3f8230a619E3c1f20e; // TTB (sorted)
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // --- Pool parameters (must match SetupSepolia) ---
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    function _buildPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _deployerKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _deployer() internal view returns (address) {
        return vm.addr(_deployerKey());
    }
}

// ============================================================
//  ACTION 1: CREATE LIMIT ORDER
// ============================================================
/// @notice Mints TTA, approves hook, creates a sell-token0 limit order.
///         Default: sell 10 TTA when price >= 1.01 (scaled 1e18).
contract CreateOrder is SepoliaConfig {
    uint96 constant ORDER_AMOUNT = 10 ether; // 10 TTA
    uint128 constant TRIGGER_PRICE = 1.01e18; // price >= 1.01 to fill

    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        console2.log("=== Create Limit Order (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:", HOOK);
        console2.log("Selling: TTA (token0), Amount:", uint256(ORDER_AMOUNT));
        console2.log("Trigger Price (1e18):", uint256(TRIGGER_PRICE));

        vm.startBroadcast(pk);

        // Step 1: Mint TTA to deployer (MockERC20 has public mint)
        MockERC20(TOKEN0).mint(deployer, uint256(ORDER_AMOUNT));
        console2.log("Minted TTA to deployer");

        // Step 2: Approve hook to pull TTA
        IERC20(TOKEN0).approve(HOOK, uint256(ORDER_AMOUNT));
        console2.log("Approved hook for TTA");

        // Step 3: Create the limit order
        PoolKey memory poolKey = _buildPoolKey();
        uint256 orderId = ILAwareLimitOrderHook(HOOK)
            .createLimitOrder(
                poolKey,
                true, // zeroForOne = sell token0 for token1
                ORDER_AMOUNT,
                TRIGGER_PRICE
            );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== ORDER CREATED ===");
        console2.log("Order ID:", orderId);
        console2.log("Direction: Sell TTA (token0) -> Receive TTB (token1)");
        console2.log("Amount:", uint256(ORDER_AMOUNT));
        console2.log("Trigger: price >= 1.01");
        console2.log("");
        console2.log("Next: Run ExecuteSwap to trigger this order");
    }
}

// ============================================================
//  ACTION 2: EXECUTE SWAP (move price to trigger orders)
// ============================================================
/// @notice Deploys a PoolSwapTest router, mints TTB, swaps TTB->TTA to push
///         the price UP (making token0 more expensive), which should trigger
///         zeroForOne sell orders.
contract ExecuteSwap is SepoliaConfig {
    // Phase 3.13: increased from 50k to 5M to guarantee price moves past 1.01
    // Pool has 10M liquidity, so 5M swap = ~50% of pool → massive price impact
    uint256 constant SWAP_AMOUNT = 100_000 ether;

    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        console2.log("=== Execute Swap (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Swap:", SWAP_AMOUNT / 1 ether, "TTB -> TTA (push price UP)");

        vm.startBroadcast(pk);

        // Step 1: Deploy PoolSwapTest router
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        console2.log("SwapRouter deployed:", address(swapRouter));

        // Step 2: Mint TTB to deployer
        MockERC20(TOKEN1).mint(deployer, SWAP_AMOUNT);
        console2.log("Minted TTB to deployer");

        // Step 3: Approve router for TTB
        IERC20(TOKEN1).approve(address(swapRouter), SWAP_AMOUNT);
        console2.log("Approved SwapRouter for TTB");

        // Step 4: Execute swap — sell TTB (token1) for TTA (token0)
        // zeroForOne = false means: selling token1 for token0
        // amountSpecified < 0 means: exact input
        PoolKey memory poolKey = _buildPoolKey();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false, // sell token1 -> buy token0
            amountSpecified: -int256(SWAP_AMOUNT), // exact input
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 // no price limit
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, swapParams, testSettings, "");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== SWAP EXECUTED ===");
        console2.log("Swapped TTB -> TTA");
        console2.log("Price should have moved UP significantly");
        console2.log("");
        console2.log("Next: Run ReadPoolState to check new price, then ReadStatus for orders");
    }
}

// ============================================================
//  ACTION 3: CANCEL ORDER
// ============================================================
/// @notice Cancels an existing order by ID. Set ORDER_ID env var before running.
contract CancelOrder is SepoliaConfig {
    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        // Read ORDER_ID from environment (default 0 for testing)
        uint256 orderId = vm.envOr("ORDER_ID", uint256(0));

        console2.log("=== Cancel Order (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Order ID:", orderId);

        // Read order state before cancel
        ILAwareLimitOrderHook hookContract = ILAwareLimitOrderHook(HOOK);
        (
            uint96 amount0,
            uint96 amount1,, // token0
            , // token1
            uint128 triggerPrice,, // createdAt
            bool isFilled,
            bool zeroForOne,
            , // vaultShares
        ) = hookContract.orders(orderId);

        console2.log("Order owner:", hookContract.ownerOf(orderId));
        console2.log("Is filled:", isFilled);
        console2.log("zeroForOne:", zeroForOne);
        console2.log("amount0:", uint256(amount0));
        console2.log("amount1:", uint256(amount1));
        console2.log("triggerPrice:", uint256(triggerPrice));

        require(hookContract.ownerOf(orderId) == deployer, "Not your order!");
        require(!isFilled, "Order already filled!");

        vm.startBroadcast(pk);

        hookContract.cancelOrder(orderId);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== ORDER CANCELLED ===");
        console2.log("Tokens refunded to:", deployer);
    }
}

// ============================================================
//  UTILITY: READ ORDER STATUS (no broadcast needed)
// ============================================================
/// @notice Read-only: check order status and pool price.
///   forge script script/InteractSepolia.s.sol:ReadStatus \
///     --rpc-url $SEPOLIA_RPC_URL -vvvv
contract ReadStatus is SepoliaConfig {
    function run() external view {
        address deployer = _deployer();
        ILAwareLimitOrderHook hookContract = ILAwareLimitOrderHook(HOOK);

        console2.log("=== Read Status (Sepolia) ===");
        console2.log("Hook:", HOOK);
        console2.log("Deployer:", deployer);

        // Next order ID (shows how many orders exist)
        uint256 nextId = hookContract.nextOrderId();
        console2.log("Total orders created:", nextId);

        // Read last few orders
        uint256 start = nextId > 5 ? nextId - 5 : 0;
        for (uint256 i = start; i < nextId; i++) {
            (uint96 amount0, uint96 amount1,,, uint128 triggerPrice,, bool isFilled, bool zeroForOne,,) =
                hookContract.orders(i);

            console2.log("---");
            console2.log("Order", i, "owner:", hookContract.ownerOf(i));
            console2.log("  filled:", isFilled, "zeroForOne:", zeroForOne);
            console2.log("  amount0:", uint256(amount0), "amount1:", uint256(amount1));
            console2.log("  triggerPrice:", uint256(triggerPrice));
        }

        // Token balances
        console2.log("---");
        console2.log("TTA balance (deployer):", IERC20(TOKEN0).balanceOf(deployer));
        console2.log("TTB balance (deployer):", IERC20(TOKEN1).balanceOf(deployer));
        console2.log("TTA balance (hook):", IERC20(TOKEN0).balanceOf(HOOK));
        console2.log("TTB balance (hook):", IERC20(TOKEN1).balanceOf(HOOK));
    }
}

// ============================================================
//  DIAGNOSTIC: READ POOL STATE (Phase 3.13)
// ============================================================
/// @notice Read on-chain pool state: current tick, sqrtPriceX96, liquidity,
///         linked list, and order eligibility.
///   forge script script/InteractSepolia.s.sol:ReadPoolState \
///     --rpc-url $SEPOLIA_RPC_URL -vvvv
contract ReadPoolState is SepoliaConfig {
    using StateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external view {
        console2.log("=== Pool State Diagnostic (Sepolia) ===");
        console2.log("Hook:", HOOK);
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("TOKEN0:", TOKEN0);
        console2.log("TOKEN1:", TOKEN1);

        PoolKey memory poolKey = _buildPoolKey();
        PoolId poolId = poolKey.toId();
        console2.log("");
        console2.log("PoolId (bytes32):");
        console2.logBytes32(PoolId.unwrap(poolId));

        // --- Slot0: tick, price, fees ---
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(POOL_MANAGER).getSlot0(poolId);

        console2.log("");
        console2.log("--- Slot0 ---");
        console2.log("sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("tick:", tick);
        console2.log("protocolFee:", uint256(protocolFee));
        console2.log("lpFee:", uint256(lpFee));

        // --- Convert sqrtPriceX96 to 1e18-scaled price ---
        // price = (sqrtPriceX96 / 2^96)^2
        // Split to avoid overflow: sqrtPrice_1e9 = sqrtPriceX96 * 1e9 / 2^96
        // Then: price_1e18 = sqrtPrice_1e9 * sqrtPrice_1e9
        uint256 sqrtPrice_1e9 = 0;
        uint256 price_1e18 = 0;

        if (sqrtPriceX96 > 0) {
            sqrtPrice_1e9 = (uint256(sqrtPriceX96) * 1e9) / (1 << 96);
            price_1e18 = sqrtPrice_1e9 * sqrtPrice_1e9;

            console2.log("");
            console2.log("--- Derived Price ---");
            console2.log("price_1e18:", price_1e18);
            console2.log("(1.00 = 1000000000000000000)");
            console2.log("(1.01 = 1010000000000000000)");
            console2.log("(1.10 = 1100000000000000000)");

            if (price_1e18 >= 1.01e18) {
                console2.log(">>> PRICE ABOVE 1.01 - orders SHOULD execute <<<");
            } else {
                uint256 gap = 1.01e18 - price_1e18;
                console2.log("Gap to 1.01 trigger:", gap);
                console2.log(">>> PRICE BELOW 1.01 - need bigger swap <<<");
            }
        } else {
            console2.log("WARNING: sqrtPriceX96 is 0 - pool may not be initialized");
        }

        // --- Liquidity ---
        uint128 liquidity = IPoolManager(POOL_MANAGER).getLiquidity(poolId);
        console2.log("");
        console2.log("--- Liquidity ---");
        console2.log("liquidity:", uint256(liquidity));

        // --- Linked List State ---
        ILAwareLimitOrderHook hookContract = ILAwareLimitOrderHook(HOOK);
        int24 sentinelMin = hookContract.SENTINEL_MIN();
        int24 sentinelMax = hookContract.SENTINEL_MAX();
        int24 firstActive = hookContract.nextActiveTick(sentinelMin);
        int24 lastActive = hookContract.prevActiveTick(sentinelMax);

        console2.log("");
        console2.log("--- Linked List ---");
        if (firstActive == sentinelMax) {
            console2.log("List: EMPTY (no active order ticks)");
        } else {
            console2.log("First active tick:", firstActive);
            console2.log("Last active tick:", lastActive);

            // Walk the list (up to 10 ticks)
            int24 cursor = firstActive;
            uint256 count = 0;
            while (cursor != sentinelMax && count < 10) {
                uint256[] memory idsAtTick = hookContract.getOrdersInTick(cursor);
                console2.log("  tick:", int256(cursor));
                console2.log("    orders:", idsAtTick.length);
                cursor = hookContract.getNextActiveTick(cursor);
                count++;
            }
        }

        // --- Orders vs Current Price ---
        uint256 nextId = hookContract.nextOrderId();
        console2.log("");
        console2.log("--- Order Eligibility ---");
        console2.log("Total orders:", nextId);

        for (uint256 i = 0; i < nextId && i < 5; i++) {
            (uint96 amount0,,,, uint128 triggerPrice,, bool isFilled, bool zeroForOne,,) =
                hookContract.orders(i);

            console2.log("");
            console2.log("Order", i);
            console2.log("  owner:", hookContract.ownerOf(i));
            console2.log("  filled:", isFilled);
            console2.log("  zeroForOne:", zeroForOne);
            console2.log("  amount0:", uint256(amount0));
            console2.log("  triggerPrice:", uint256(triggerPrice));

            if (price_1e18 > 0 && !isFilled) {
                bool eligible =
                    zeroForOne ? (price_1e18 >= uint256(triggerPrice)) : (price_1e18 <= uint256(triggerPrice));
                console2.log("  >>> ELIGIBLE:", eligible);
            }
        }
    }
}
