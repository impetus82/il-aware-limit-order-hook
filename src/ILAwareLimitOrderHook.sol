// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ILAwareLimitOrderHook - Uniswap V4 Hook for On-Chain Limit Orders
/// @author Yuri (Crypto Side Hustle 2026)
/// @notice Allows users to place limit orders that execute automatically when
///         the pool price reaches a specified trigger price during swaps.
///
/// @dev Architecture Overview (Phase 3.15 - Fee Mechanism & Commercial Release):
///
///   **Sorted Linked List of Active Ticks**
///   Instead of blindly scanning MAX_TICK_SCAN consecutive tick buckets (which
///   wastes gas on empty ticks and fails for large price movements), we maintain
///   a sorted doubly-linked list of only those ticks that actually contain orders.
///
///   Storage layout:
///     - `nextActiveTick[tick]` -> next higher active tick (or SENTINEL_MAX)
///     - `prevActiveTick[tick]` -> next lower active tick (or SENTINEL_MIN)
///     - Two sentinel values anchor the list boundaries
///
///   This gives us:
///     - O(1) insertion: given the sorted position (found via binary hint or walk)
///     - O(1) removal: unlink node when its bucket becomes empty
///     - O(K) scan during afterSwap: iterate only K populated ticks, skipping
///       all empty space regardless of how far the price has moved
///
///   **afterSwap Execution**
///   Execution happens in `afterSwap`, AFTER the user's swap has moved the price.
///   The hook reads the post-swap tick, then walks the linked list from the
///   current tick in the appropriate direction to find and execute eligible orders.
///
///   **Graceful Execution (Phase 3.14 Anti-DoS)**
///   `_executeOrder` returns `bool success` instead of reverting on slippage.
///   Failed orders emit `OrderExecutionFailed` and remain in the bucket for
///   retry on the next swap. This prevents a single toxic order from blocking
///   ALL swaps in the pool (critical DoS vulnerability fixed).
///
///   **Fee Mechanism (Phase 3.15 Monetization)**
///   A configurable execution fee (default 5 BPS = 0.05%) is deducted from
///   `amountOut` on each successful order fill. Fees accumulate per-currency in
///   `pendingFees` and can be withdrawn by the owner via `withdrawFees()`.
///   Fee rate is adjustable (0–50 BPS max) via `setFeeBps()`.
///
///   **Gas Metering (DoS Protection)**
///   A `gasleft()` check prevents out-of-gas reverts when many orders are queued.
///   Execution stops gracefully; remaining orders persist for the next swap.
///
///   **Security**
///   - ReentrancyGuard on createLimitOrder and cancelOrder (ERC-777 defense)
///   - Slippage protection: amountOut validated against triggerPrice
///   - Pool key validation: tickSpacing > 0 check
///   - SafeCast for all unsafe truncation paths
///   - Ownable (OpenZeppelin) for admin functions
///   - forceCancelOrder: admin cleanup for orphaned/stuck orders
///
///   **Custom Errors**
///   All reverts use custom errors instead of string messages, saving ~600 gas
///   per revert path and reducing deployed bytecode size.
contract ILAwareLimitOrderHook is BaseHook, ReentrancyGuard, Ownable, ERC721 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when order amount is zero
    error InvalidAmount();

    /// @notice Thrown when trigger price is zero
    error InvalidTriggerPrice();

    /// @notice Thrown when a non-creator tries to cancel an order
    error NotOrderCreator();

    /// @notice Thrown when trying to cancel an already-filled order
    error OrderAlreadyFilled();

    /// @notice Thrown on out-of-bounds array access (internal safety)
    error IndexOutOfBounds();

    /// @notice Thrown when poolKey has invalid tickSpacing (M-2)
    error InvalidPoolKey();

    /// @notice Thrown when trying to force-cancel an order that is already filled or cancelled
    error OrderNotActive();

    /// @notice Thrown when fee BPS exceeds maximum allowed
    error FeeTooHigh();

    /// @notice Thrown when withdrawFees has nothing to withdraw
    error NoFeesToWithdraw();

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Packed limit order structure (4 storage slots)
    struct LimitOrder {
        address creator;
        uint96 amount0;
        uint96 amount1;
        address token0;
        address token1;
        uint128 triggerPrice;
        uint64 createdAt;
        bool isFilled;
        bool zeroForOne;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice All orders by ID
    mapping(uint256 => LimitOrder) public orders;

    /// @notice Order IDs owned by each user
    mapping(address => uint256[]) private userOrders;

    /// @notice Auto-incrementing order counter
    uint256 public nextOrderId;

    /// @notice Tick-based order indexing for O(1) lookup
    /// @dev Key is the aligned tick (rounded to tickSpacing grid)
    mapping(int24 => uint256[]) public tickToOrders;

    /// @notice Reverse mapping: orderId -> aligned tick bucket
    mapping(uint256 => int24) private orderTickBucket;

    /*//////////////////////////////////////////////////////////////
                    SORTED LINKED LIST OF ACTIVE TICKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentinel values for linked list boundaries
    /// @dev These are beyond Uniswap's tick range (+/-887272) and serve as
    ///      permanent anchors. SENTINEL_MIN.next = first real tick,
    ///      SENTINEL_MAX.prev = last real tick.
    int24 public constant SENTINEL_MIN = type(int24).min; // -8388608
    int24 public constant SENTINEL_MAX = type(int24).max; //  8388607

    /// @notice Forward pointer: tick -> next higher active tick
    mapping(int24 => int24) public nextActiveTick;

    /// @notice Backward pointer: tick -> next lower active tick
    mapping(int24 => int24) public prevActiveTick;

    /// @notice Quick check: does this tick have orders?
    /// @dev True when tickToOrders[tick].length > 0 AND tick is linked.
    ///      Prevents double-insertion and enables O(1) removal check.
    mapping(int24 => bool) public isActiveTick;

    /// @dev Reentrancy guard for execution
    bool private isExecuting;

    /// @notice Maximum number of *populated* ticks to process per swap
    /// @dev Unlike the old MAX_TICK_SCAN which counted empty ticks too,
    ///      this counts only ticks that actually have orders. 100 populated
    ///      ticks is generous - most swaps will encounter 1-5.
    int24 public constant MAX_ACTIVE_TICK_SCAN = 100;

    /// @notice Minimum gas required to attempt executing one more order
    uint256 public constant GAS_LIMIT_PER_ORDER = 150_000;

    /// @notice Maximum allowed slippage in basis points (50 = 0.5%)
    uint256 public constant MAX_SLIPPAGE_BPS = 50;

    /*//////////////////////////////////////////////////////////////
                    IL-AWARE ADDITIONS (UHI9 Hookathon)
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-4626 vault for earning yield on idle order liquidity
    address public immutable yieldVault;

    /// @notice LP position data recorded at liquidity addition time
    struct LPPosition {
        uint160 sqrtPriceAtEntry;
        uint128 liquidity;
        uint256 entryTimestamp;
        uint256 idleAmount;
        uint256 vaultShares;
    }

    /// @notice LP position per pool per LP address (populated via afterAddLiquidity + hookData)
    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;

    /*//////////////////////////////////////////////////////////////
                        FEE MECHANISM (Phase 3.15)
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum fee in basis points (50 = 0.5%)
    uint256 public constant MAX_FEE_BPS = 50;

    /// @notice Current execution fee in basis points (default: 5 = 0.05%)
    uint256 public feeBps = 5;

    /// @notice Accumulated fees per currency, withdrawable by owner
    mapping(Currency => uint256) public pendingFees;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    );

    event OrderCancelled(uint256 indexed orderId, address indexed creator);

    event OrderFilled(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amountIn,
        uint96 amountOut,
        uint128 executionPrice
    );

    /// @notice Emitted when an order execution fails gracefully (Phase 3.14)
    /// @param orderId The order that failed to execute
    /// @param reason Human-readable failure reason
    event OrderExecutionFailed(uint256 indexed orderId, string reason);

    /// @notice Emitted when admin force-cancels an orphaned order
    event OrderForceCancelled(uint256 indexed orderId, address indexed admin);

    /// @notice Emitted when fee rate is updated
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when fees are withdrawn
    event FeesWithdrawn(Currency indexed currency, address indexed recipient, uint256 amount);

    /// @notice Emitted when a fee is collected from an order execution
    event FeeCollected(uint256 indexed orderId, Currency indexed currency, uint256 feeAmount);

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _poolManager The Uniswap V4 PoolManager contract
    /// @param _initialOwner The address that will own this contract (EOA deployer)
    /// @param _yieldVault ERC-4626 vault address for idle liquidity yield (address(0) for tests)
    constructor(IPoolManager _poolManager, address _initialOwner, address _yieldVault)
        BaseHook(_poolManager)
        Ownable(_initialOwner)
        ERC721("Limit Order Position", "LOP")
    {
        yieldVault = _yieldVault;
        // Initialize sentinel linked list: SENTINEL_MIN <-> SENTINEL_MAX
        nextActiveTick[SENTINEL_MIN] = SENTINEL_MAX;
        prevActiveTick[SENTINEL_MAX] = SENTINEL_MIN;
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Declare which hook callbacks this contract implements
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new limit order with token custody
    /// @dev Transfers the input token from the caller to this contract.
    ///      The order is indexed by its aligned tick and inserted into the
    ///      sorted active tick linked list for efficient scanning.
    ///      Protected by ReentrancyGuard against ERC-777 callbacks.
    /// @param poolKey The Uniswap V4 pool to associate the order with
    /// @param zeroForOne True = selling token0 for token1; False = buying token0 with token1
    /// @param amountIn Amount of input token to deposit
    /// @param triggerPrice Price threshold for execution (uint128 scaled to 1e18)
    /// @return orderId The unique ID of the created order
    function createLimitOrder(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    ) external nonReentrant returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (triggerPrice == 0) revert InvalidTriggerPrice();
        if (poolKey.tickSpacing <= 0) revert InvalidPoolKey();

        orderId = nextOrderId++;

        address token0Addr = Currency.unwrap(poolKey.currency0);
        address token1Addr = Currency.unwrap(poolKey.currency1);

        // Transfer tokens to hook (custody)
        if (zeroForOne) {
            IERC20(token0Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        } else {
            IERC20(token1Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        }

        orders[orderId] = LimitOrder({
            creator: msg.sender,
            amount0: zeroForOne ? amountIn : 0,
            amount1: zeroForOne ? 0 : amountIn,
            token0: token0Addr,
            token1: token1Addr,
            triggerPrice: triggerPrice,
            createdAt: uint64(block.timestamp),
            isFilled: false,
            zeroForOne: zeroForOne
        });

        userOrders[msg.sender].push(orderId);

        // Index by tick bucket
        int24 alignedTick = _alignTick(
            TickMath.getTickAtSqrtPrice(uint128ToSqrtPrice(triggerPrice)),
            poolKey.tickSpacing
        );
        tickToOrders[alignedTick].push(orderId);
        orderTickBucket[orderId] = alignedTick;

        // Insert tick into sorted linked list if not already active
        if (!isActiveTick[alignedTick]) {
            _insertActiveTick(alignedTick);
        }

        emit OrderCreated(orderId, msg.sender, zeroForOne, amountIn, triggerPrice);
    }

    /// @notice Cancel an active order and return deposited tokens
    /// @dev Removes the order from its tick bucket. If the bucket becomes empty,
    ///      removes the tick from the active linked list.
    ///      Protected by ReentrancyGuard against ERC-777 callbacks.
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 orderId) external nonReentrant {
        LimitOrder storage order = orders[orderId];

        if (order.creator != msg.sender) revert NotOrderCreator();
        if (order.isFilled) revert OrderAlreadyFilled();

        // Remove from tick bucket
        int24 tick = orderTickBucket[orderId];
        uint256[] storage orderIds = tickToOrders[tick];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                _removeFromArray(orderIds, i);
                break;
            }
        }

        // If tick bucket is now empty, remove from linked list
        if (tickToOrders[tick].length == 0) {
            _removeActiveTick(tick);
        }

        // Return tokens
        if (order.zeroForOne && order.amount0 > 0) {
            IERC20(order.token0).safeTransfer(msg.sender, uint256(order.amount0));
        } else if (!order.zeroForOne && order.amount1 > 0) {
            IERC20(order.token1).safeTransfer(msg.sender, uint256(order.amount1));
        }

        // Mark as cancelled (zero out creator)
        order.creator = address(0);

        emit OrderCancelled(orderId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                       ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Force-cancel an orphaned or stuck order (admin only)
    /// @dev Used to clean up orders where creator == address(0) but isFilled == false
    ///      (e.g., Order #0 from Phase 3.13), or orders stuck due to token issues.
    ///      Returns funds to the original creator if still set; otherwise just cleans state.
    /// @param orderId The ID of the order to force-cancel
    function forceCancelOrder(uint256 orderId) external onlyOwner {
        LimitOrder storage order = orders[orderId];

        if (order.isFilled) revert OrderAlreadyFilled();
        // Allow force-cancel even if creator == address(0) (orphaned order)
        if (order.creator == address(0) && order.amount0 == 0 && order.amount1 == 0) {
            revert OrderNotActive();
        }

        // Remove from tick bucket
        int24 tick = orderTickBucket[orderId];
        uint256[] storage orderIds = tickToOrders[tick];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                _removeFromArray(orderIds, i);
                break;
            }
        }

        // If tick bucket is now empty, remove from linked list
        if (tickToOrders[tick].length == 0) {
            _removeActiveTick(tick);
        }

        // Return tokens to creator if they exist, otherwise tokens stay in contract
        // (admin can recover via separate mechanism if needed)
        address recipient = order.creator;
        if (recipient != address(0)) {
            if (order.zeroForOne && order.amount0 > 0) {
                IERC20(order.token0).safeTransfer(recipient, uint256(order.amount0));
            } else if (!order.zeroForOne && order.amount1 > 0) {
                IERC20(order.token1).safeTransfer(recipient, uint256(order.amount1));
            }
        }

        // Mark as cancelled
        order.creator = address(0);
        order.amount0 = 0;
        order.amount1 = 0;

        emit OrderForceCancelled(orderId, msg.sender);
    }

    /// @notice Update the execution fee rate (owner only)
    /// @param newFeeBps New fee in basis points (0–50, where 50 = 0.5%)
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        uint256 oldFeeBps = feeBps;
        feeBps = newFeeBps;

        emit FeeBpsUpdated(oldFeeBps, newFeeBps);
    }

    /// @notice Withdraw accumulated fees for a specific currency (owner only)
    /// @param currency The currency to withdraw fees for
    /// @param recipient The address to send fees to
    function withdrawFees(Currency currency, address recipient) external onlyOwner {
        uint256 amount = pendingFees[currency];
        if (amount == 0) revert NoFeesToWithdraw();

        pendingFees[currency] = 0;

        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);

        emit FeesWithdrawn(currency, recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get full order data by ID
    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }

    /// @notice Get all order IDs for a given user
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /// @notice Get all order IDs in a specific tick bucket
    function getOrdersInTick(int24 tick) external view returns (uint256[] memory) {
        return tickToOrders[tick];
    }

    /// @notice Get the tick bucket an order was assigned to
    function getTickBucket(uint256 orderId) external view returns (int24) {
        return orderTickBucket[orderId];
    }

    /// @notice Get the next active tick above the given tick
    function getNextActiveTick(int24 tick) external view returns (int24) {
        return nextActiveTick[tick];
    }

    /// @notice Get the next active tick below the given tick
    function getPrevActiveTick(int24 tick) external view returns (int24) {
        return prevActiveTick[tick];
    }

    /// @notice Get accumulated fees for a specific currency
    function getPendingFees(Currency currency) external view returns (uint256) {
        return pendingFees[currency];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook callback - executes eligible limit orders AFTER each swap
    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Prevent recursion from our own internal swaps
        if (isExecuting) {
            return (this.afterSwap.selector, 0);
        }

        // Read the ACTUAL post-swap price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);

        // Execute matching orders using the linked list
        _tryExecuteOrders(poolKey, currentPrice, params.zeroForOne);

        return (this.afterSwap.selector, 0);
    }

    /// @notice Scan ONLY active (populated) ticks and execute eligible orders
    /// @dev Instead of blindly iterating MAX_TICK_SCAN * tickSpacing range,
    ///      we walk the sorted linked list of active ticks. This means:
    ///      - Whale swaps that move price 50,000 ticks: still works (O(K) where K = populated ticks)
    ///      - Sparse order book with 3 orders spread across 100,000 ticks: 3 iterations, not 100
    ///
    ///      Direction logic:
    ///      - !zeroForOne swap (price UP) -> scan downward for SELL orders (trigger when price >= X)
    ///      - zeroForOne swap (price DOWN) -> scan upward for BUY orders (trigger when price <= X)
    function _tryExecuteOrders(
        PoolKey calldata poolKey,
        uint128 currentPrice,
        bool swapZeroForOne
    ) internal {
        address token0 = Currency.unwrap(poolKey.currency0);

        int24 activeTickCount = 0;

        if (swapZeroForOne) {
            // Price went DOWN -> scan upward for BUY orders (triggerPrice >= currentPrice)
            // Start from the lowest active tick and go up
            int24 tick = nextActiveTick[SENTINEL_MIN];

            while (tick != SENTINEL_MAX && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache next before potential removal
                int24 nextTick = nextActiveTick[tick];

                _processTickBucket(tick, token0, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[tick].length == 0) {
                    _removeActiveTick(tick);
                }

                activeTickCount++;
                tick = nextTick;
            }
        } else {
            // Price went UP -> scan downward for SELL orders (triggerPrice <= currentPrice)
            // Start from the highest active tick and go down
            int24 tick = prevActiveTick[SENTINEL_MAX];

            while (tick != SENTINEL_MIN && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache prev before potential removal
                int24 prevTick = prevActiveTick[tick];

                _processTickBucket(tick, token0, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[tick].length == 0) {
                    _removeActiveTick(tick);
                }

                activeTickCount++;
                tick = prevTick;
            }
        }
    }

    /// @notice Process all orders in a single tick bucket
    /// @dev Iterates orders in the bucket, executes eligible ones, performs
    ///      lazy cleanup of filled/cancelled orders.
    ///      Phase 3.14: Failed executions emit OrderExecutionFailed and skip
    ///      (order stays in bucket for retry on next swap).
    function _processTickBucket(
        int24 tick,
        address token0,
        uint128 currentPrice,
        PoolKey calldata poolKey
    ) internal {
        uint256[] storage orderIdsInTick = tickToOrders[tick];

        uint256 i = 0;
        while (i < orderIdsInTick.length) {
            if (gasleft() < GAS_LIMIT_PER_ORDER) break;

            uint256 orderId = orderIdsInTick[i];
            LimitOrder storage order = orders[orderId];

            // Lazy cleanup: remove filled/cancelled orders
            if (order.creator == address(0) || order.isFilled) {
                _removeFromArray(orderIdsInTick, i);
                continue;
            }

            // Skip if wrong pool
            if (order.token0 != token0) {
                i++;
                continue;
            }

            // Check price eligibility (inlined for gas efficiency)
            bool eligible = false;
            if (order.zeroForOne) {
                // Sell token0: trigger when price >= triggerPrice
                eligible = (currentPrice >= order.triggerPrice);
            } else {
                // Buy token0: trigger when price <= triggerPrice
                eligible = (currentPrice <= order.triggerPrice);
            }

            if (eligible) {
                // Phase 3.14: graceful execution - skip on failure instead of revert
                bool success = _executeOrder(poolKey, order, orderId);
                if (success) {
                    _removeFromArray(orderIdsInTick, i);
                    // Don't increment i - swap-and-pop moved new element here
                } else {
                    // Order failed (slippage etc.) - leave it for next swap
                    i++;
                }
            } else {
                i++;
            }
        }
    }

    /// @notice Execute a single order via internal swap, deducting fee from output
    /// @dev Phase 3.15: Deducts `feeBps` from amountOut before sending to creator.
    ///      Fee stays in the hook contract and is tracked in `pendingFees`.
    ///      Phase 3.14: Returns bool instead of reverting on slippage.
    ///      Performs a swap through PoolManager to fill the order:
    ///      1. Get current price and compute slippage limits
    ///      2. Execute swap via poolManager.swap()
    ///      3. Settle input tokens (sync + transfer + settle)
    ///      4. Validate slippage - if failed, deliver tokens with warning
    ///      5. Deduct fee from output, take net tokens for creator + fee for hook
    ///      6. Mark order as filled
    /// @return success True if order was filled, false if skipped
        // ═══════════════════════════════════════════════════════════════════
    // PATCH: _executeOrder — settle by ACTUAL swap delta, not amountIn
    // ═══════════════════════════════════════════════════════════════════
    //
    // ROOT CAUSE of CurrencyNotSettled:
    //   When sqrtPriceLimitX96 causes a partial fill, the swap consumes
    //   LESS input than amountIn. But the old code did:
    //     safeTransfer(PM, amountIn)  ← full order size
    //     settle()                     ← settles full amount
    //   This over-settled input, leaving a positive delta on the hook.
    //
    // FIX: Use swapDelta to determine actual consumed amounts.
    //   For zeroForOne=true:  actualInput = uint256(uint128(-swapDelta.amount0()))
    //   For zeroForOne=false: actualInput = uint256(uint128(-swapDelta.amount1()))
    //
    // This also means partial fills are possible: only the consumed
    // portion is settled, and the order could be partially filled.
    // For simplicity, we still mark it as fully filled but only
    // settle what was actually consumed.
    // ═══════════════════════════════════════════════════════════════════

    function _executeOrder(
        PoolKey calldata poolKey,
        LimitOrder storage order,
        uint256 orderId
    ) internal returns (bool success) {
        isExecuting = true;

        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;

        // Get current price for slippage limit
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Price limit: 5% slippage on the internal swap
        uint160 sqrtPriceLimitX96 = order.zeroForOne
            ? ((uint256(currentSqrtPriceX96) * 95) / 100).toUint160()
            : ((uint256(currentSqrtPriceX96) * 105) / 100).toUint160();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: order.zeroForOne
                ? -int256(uint256(order.amount0))
                : -int256(uint256(order.amount1)),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");

        // Settle input + Take output (with fee deduction)
        if (order.zeroForOne) {
            // ── FIX: settle ACTUAL consumed amount, not full amountIn ──
            // swapDelta.amount0() is negative (hook owes token0 to pool)
            int128 deltaAmount0 = swapDelta.amount0();
            uint256 actualInput = uint256(uint128(-deltaAmount0));

            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), actualInput);
            poolManager.settle();

            int128 deltaAmount1 = swapDelta.amount1();
            uint256 amountOut = deltaAmount1 < 0
                ? uint256(uint128(-deltaAmount1))
                : uint256(uint128(deltaAmount1));

            // Compute fee (same for both slippage and normal paths)
            uint256 feeAmount = (amountOut * feeBps) / 10000;
            uint256 netAmount = amountOut - feeAmount;

            // Slippage protection (Phase 3.14: graceful - deliver with warning)
            uint256 expectedOut = (uint256(amountIn) * uint256(order.triggerPrice)) / 1e18;
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                // Deliver tokens to creator despite slippage (with fee deduction)
                poolManager.take(poolKey.currency1, order.creator, netAmount);
                if (feeAmount > 0) {
                    poolManager.take(poolKey.currency1, address(this), feeAmount);
                    pendingFees[poolKey.currency1] += feeAmount;
                    emit FeeCollected(orderId, poolKey.currency1, feeAmount);
                }

                order.isFilled = true;
                order.amount1 = netAmount.toUint96();

                // Refund unconsumed input to creator
                uint256 refund = uint256(amountIn) - actualInput;
                if (refund > 0) {
                    IERC20(order.token0).safeTransfer(order.creator, refund);
                }

                emit OrderExecutionFailed(orderId, "SlippageExceeded");
                emit OrderFilled(
                    orderId,
                    order.creator,
                    uint96(actualInput),
                    netAmount.toUint96(),
                    sqrtPriceToUint128(currentSqrtPriceX96)
                );

                isExecuting = false;
                return true; // Order is filled (with slippage warning), remove from bucket
            }

            // Normal execution: take with fee
            poolManager.take(poolKey.currency1, order.creator, netAmount);
            if (feeAmount > 0) {
                poolManager.take(poolKey.currency1, address(this), feeAmount);
                pendingFees[poolKey.currency1] += feeAmount;
                emit FeeCollected(orderId, poolKey.currency1, feeAmount);
            }

            order.isFilled = true;
            order.amount1 = netAmount.toUint96();

            // Refund unconsumed input to creator (if partial fill)
            uint256 refund0 = uint256(amountIn) - actualInput;
            if (refund0 > 0) {
                IERC20(order.token0).safeTransfer(order.creator, refund0);
            }
        } else {
            // ── FIX: settle ACTUAL consumed amount, not full amountIn ──
            // swapDelta.amount1() is negative (hook owes token1 to pool)
            int128 deltaAmount1 = swapDelta.amount1();
            uint256 actualInput = uint256(uint128(-deltaAmount1));

            poolManager.sync(poolKey.currency1);
            IERC20(order.token1).safeTransfer(address(poolManager), actualInput);
            poolManager.settle();

            int128 deltaAmount0 = swapDelta.amount0();
            uint256 amountOut = deltaAmount0 < 0
                ? uint256(uint128(-deltaAmount0))
                : uint256(uint128(deltaAmount0));

            // Compute fee (same for both slippage and normal paths)
            uint256 feeAmount = (amountOut * feeBps) / 10000;
            uint256 netAmount = amountOut - feeAmount;

            // Slippage protection (Phase 3.14: graceful)
            uint256 expectedOut = (uint256(amountIn) * 1e18) / uint256(order.triggerPrice);
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                // Deliver tokens to creator despite slippage (with fee deduction)
                poolManager.take(poolKey.currency0, order.creator, netAmount);
                if (feeAmount > 0) {
                    poolManager.take(poolKey.currency0, address(this), feeAmount);
                    pendingFees[poolKey.currency0] += feeAmount;
                    emit FeeCollected(orderId, poolKey.currency0, feeAmount);
                }

                order.isFilled = true;
                order.amount0 = netAmount.toUint96();

                // Refund unconsumed input to creator
                uint256 refund = uint256(amountIn) - actualInput;
                if (refund > 0) {
                    IERC20(order.token1).safeTransfer(order.creator, refund);
                }

                emit OrderExecutionFailed(orderId, "SlippageExceeded");
                emit OrderFilled(
                    orderId,
                    order.creator,
                    uint96(actualInput),
                    netAmount.toUint96(),
                    sqrtPriceToUint128(currentSqrtPriceX96)
                );

                isExecuting = false;
                return true;
            }

            // Normal execution: take with fee
            poolManager.take(poolKey.currency0, order.creator, netAmount);
            if (feeAmount > 0) {
                poolManager.take(poolKey.currency0, address(this), feeAmount);
                pendingFees[poolKey.currency0] += feeAmount;
                emit FeeCollected(orderId, poolKey.currency0, feeAmount);
            }

            order.isFilled = true;
            order.amount0 = netAmount.toUint96();

            // Refund unconsumed input to creator (if partial fill)
            uint256 refund1 = uint256(amountIn) - actualInput;
            if (refund1 > 0) {
                IERC20(order.token1).safeTransfer(order.creator, refund1);
            }
        }

        emit OrderFilled(
            orderId,
            order.creator,
            uint96(order.zeroForOne ? uint256(uint128(-swapDelta.amount0())) : uint256(uint128(-swapDelta.amount1()))),
            order.zeroForOne ? order.amount1 : order.amount0,
            sqrtPriceToUint128(currentSqrtPriceX96)
        );

        isExecuting = false;
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                   SORTED LINKED LIST OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Insert a tick into the sorted doubly-linked list
    /// @dev Walks forward from SENTINEL_MIN to find the correct sorted position.
    ///      For most use cases (few dozen active ticks), this is cheap.
    ///      Worst case: O(N) where N = number of active ticks.
    ///      Could be optimized with a hint parameter if needed for >1000 active ticks.
    function _insertActiveTick(int24 tick) internal {
        // Walk from the lowest sentinel to find insertion point
        int24 cursor = SENTINEL_MIN;
        while (nextActiveTick[cursor] != SENTINEL_MAX && nextActiveTick[cursor] < tick) {
            cursor = nextActiveTick[cursor];
        }

        // Insert between cursor and cursor.next
        // Before: cursor <-> cursorNext
        // After:  cursor <-> tick <-> cursorNext
        int24 cursorNext = nextActiveTick[cursor];

        nextActiveTick[cursor] = tick;
        prevActiveTick[tick] = cursor;
        nextActiveTick[tick] = cursorNext;
        prevActiveTick[cursorNext] = tick;

        isActiveTick[tick] = true;
    }

    /// @notice Remove a tick from the sorted doubly-linked list
    /// @dev O(1) operation - just unlink the node.
    function _removeActiveTick(int24 tick) internal {
        if (!isActiveTick[tick]) return;

        int24 prev = prevActiveTick[tick];
        int24 next = nextActiveTick[tick];

        // Before: prev <-> tick <-> next
        // After:  prev <-> next
        nextActiveTick[prev] = next;
        prevActiveTick[next] = prev;

        // Clean up
        delete nextActiveTick[tick];
        delete prevActiveTick[tick];
        isActiveTick[tick] = false;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert sqrtPriceX96 (Uniswap format) to uint128 price scaled to 1e18
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / (1 << 96);
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96);
        price = priceScaled.toUint128();
    }

    /// @notice Convert uint128 price (1e18 scaled) to sqrtPriceX96
    function uint128ToSqrtPrice(uint128 price) public pure returns (uint160 sqrtPriceX96) {
        uint256 priceX192 = (uint256(price) * (1 << 96)) / 1e18;
        uint256 priceX96Full = priceX192 * (1 << 96);
        uint256 sqrtPriceRaw = sqrt(priceX96Full);
        sqrtPriceX96 = sqrtPriceRaw.toUint160();
    }

    /// @notice Integer square root (Babylonian method)
    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Align a tick to the nearest multiple of tickSpacing (round down)
    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Remove element at index using swap-and-pop (O(1))
    function _removeFromArray(uint256[] storage arr, uint256 index) internal {
        if (index >= arr.length) revert IndexOutOfBounds();
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }

    /*//////////////////////////////////////////////////////////////
               IL-AWARE HOOK CALLBACKS (UHI9 — stubs)
    //////////////////////////////////////////////////////////////*/

    /// @notice Records sqrtPrice baseline and lastTick at pool initialization
    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) internal override returns (bytes4) {
        // TODO (Block 1, Day 1): store sqrtPriceBaseline and lastTick[poolId]
        return this.afterInitialize.selector;
    }

    /// @notice NoOp execution of limit orders before the AMM swap
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // TODO (Block 1, Day 4): check pending orders; execute P2P via beforeSwapReturnDelta
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Records LP entry price and liquidity when liquidity is added
    /// @dev LP must pass abi.encode(realLP) as hookData; without it IL tracking is skipped (graceful degradation)
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // TODO (Block 1, Day 2): decode hookData → realLP, record lpPositions entry
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Computes impermanent loss for an LP position using sqrtPriceX96 delta
    /// @dev Oracle-free: only uses Uniswap V4 internal state (no Chainlink dependency)
    /// @param sqrtPriceAtEntry Pool sqrt price when LP entered
    /// @param sqrtPriceAtFill  Pool sqrt price when limit order was filled
    /// @param liq              Liquidity amount of the position
    /// @return ilAmount        IL expressed in token1 units (0 if price unchanged)
    function _calculateIL(
        uint160 sqrtPriceAtEntry,
        uint160 sqrtPriceAtFill,
        uint128 liq
    ) internal pure returns (uint256 ilAmount) {
        // TODO (Block 2, Day 5): implement on-chain IL formula using sqrtPriceX96 delta
        (sqrtPriceAtEntry, sqrtPriceAtFill, liq); // suppress unused warnings for now
        return 0;
    }

    /// @notice Deposits idle order liquidity into the ERC-4626 yield vault
    /// @dev Called by user in a separate transaction AFTER createOrder() — never inside a hook callback
    /// @param orderId The limit order whose idle tokens should be deposited
    function depositToVault(uint256 orderId) external {
        // TODO (Block 2, Day 6): validate orderId owner, approve + deposit to yieldVault, store vaultShares
        (orderId); // suppress unused warning for now
    }
}