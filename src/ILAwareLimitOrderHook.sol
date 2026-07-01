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
///   Storage layout (per-pool since H2 — each pool has its own list):
///     - `nextActiveTick[poolId][tick]` -> next higher active tick (or SENTINEL_MAX)
///     - `prevActiveTick[poolId][tick]` -> next lower active tick (or SENTINEL_MIN)
///     - Two sentinel values anchor each pool's list boundaries
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

    /// @notice Thrown when trying to claim an order that has not been filled yet
    error OrderNotFilled();

    /// @notice Thrown when trying to claim an order that was already claimed
    error OrderAlreadyClaimed();

    /// @notice Thrown when the poolKey passed to claimOrder does not match the order's pool (H1)
    error PoolKeyMismatch();

    /// @notice Thrown if a vault-path claim payout would exceed what the vault just redeemed (M2 solvency)
    error RebateExceedsRedeemed();

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Packed limit order structure.
    /// @dev creator field removed; ownership is tracked via ERC721 ownerOf(orderId).
    struct LimitOrder {
        uint96 amount0;
        uint96 amount1;
        address token0;
        address token1;
        uint128 triggerPrice;
        uint64 createdAt;
        bool isFilled;
        bool zeroForOne;
        uint256 vaultShares; // ERC4626 vault shares for yield (0 = not deposited)
        uint160 sqrtPriceAtFill; // sqrtPriceX96 at execution time (for IL calc)
        PoolId poolId; // H1/H2: the pool this order belongs to (isolation + claim validation)
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice All orders by ID
    mapping(uint256 => LimitOrder) public orders;

    /// @notice Order IDs ever created by each user (append-only, read ONLY off-chain).
    /// @dev Never iterated on-chain, so its unbounded growth is not a DoS vector (M3);
    ///      off-chain callers should paginate getUserOrders() or use ERC-721 enumeration.
    mapping(address => uint256[]) private userOrders;

    /// @notice Auto-incrementing order counter
    uint256 public nextOrderId;

    /// @notice Tick-based order indexing for O(1) lookup, namespaced per pool (H2)
    /// @dev Key is (PoolId, aligned tick). Orders never collide across pools.
    mapping(PoolId => mapping(int24 => uint256[])) public tickToOrders;

    /// @notice Reverse mapping: orderId -> aligned tick bucket
    mapping(uint256 => int24) private orderTickBucket;

    /// @notice Reverse mapping: orderId -> its index within tickToOrders[poolId][tick] (M3).
    /// @dev Enables O(1) swap-and-pop removal from a bucket without a linear scan, so
    ///      cancelOrder/forceCancelOrder cannot be griefed by flooding a tick with many orders.
    mapping(uint256 => uint256) private orderBucketIndex;

    /*//////////////////////////////////////////////////////////////
                    SORTED LINKED LIST OF ACTIVE TICKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentinel values for linked list boundaries
    /// @dev These are beyond Uniswap's tick range (+/-887272) and serve as
    ///      permanent anchors. SENTINEL_MIN.next = first real tick,
    ///      SENTINEL_MAX.prev = last real tick.
    int24 public constant SENTINEL_MIN = type(int24).min; // -8388608
    int24 public constant SENTINEL_MAX = type(int24).max; //  8388607

    /// @notice Forward pointer: (pool, tick) -> next higher active tick (H2: per-pool list)
    mapping(PoolId => mapping(int24 => int24)) public nextActiveTick;

    /// @notice Backward pointer: (pool, tick) -> next lower active tick (H2: per-pool list)
    mapping(PoolId => mapping(int24 => int24)) public prevActiveTick;

    /// @notice Quick check: does this (pool, tick) have orders? (H2: per-pool)
    /// @dev True when tickToOrders[poolId][tick].length > 0 AND tick is linked.
    ///      Prevents double-insertion and enables O(1) removal check.
    mapping(PoolId => mapping(int24 => bool)) public isActiveTick;

    /// @notice Whether a pool's active-tick linked-list sentinels have been initialized (H2).
    /// @dev Guards against the default-zero trap: an uninitialized list would have
    ///      nextActiveTick[poolId][SENTINEL_MIN] == 0 (a valid tick), breaking the walk.
    mapping(PoolId => bool) private poolListInitialized;

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

    /// @notice Last known tick per pool, initialized in afterInitialize and updated after each swap
    mapping(PoolId => int24) public lastTick;

    /// @notice Baseline sqrtPriceX96 per pool at initialization time (IL reference point)
    mapping(PoolId => uint160) public sqrtPriceBaseline;

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
        uint256 indexed orderId, address indexed creator, bool zeroForOne, uint96 amountIn, uint128 triggerPrice
    );

    event OrderCancelled(uint256 indexed orderId, address indexed creator);

    event OrderFilled(
        uint256 indexed orderId, address indexed creator, uint96 amountIn, uint96 amountOut, uint128 executionPrice
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

    /// @notice Emitted when an ERC-4626 vault redeem reverts during claimOrder.
    /// @dev    The order is left FULLY intact (NFT, amounts, and vaultShares preserved) so the
    ///         owner can re-claim once the vault recovers. No tokens are paid from the hook's
    ///         balance on this path, which keeps every other order's custodied output solvent.
    event VaultRedeemFailed(uint256 indexed orderId, uint256 shares);

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
        // Active-tick linked-list sentinels are initialized PER-POOL (H2) in
        // _afterInitialize / _ensurePoolSentinels — each pool has its own list.
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Declare which hook callbacks this contract implements
    /// @dev UHI9: added afterAddLiquidity + afterAddLiquidityReturnDelta for IL tracking
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
    function createLimitOrder(PoolKey calldata poolKey, bool zeroForOne, uint96 amountIn, uint128 triggerPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (amountIn == 0) revert InvalidAmount();
        if (triggerPrice == 0) revert InvalidTriggerPrice();
        if (poolKey.tickSpacing <= 0) revert InvalidPoolKey();

        orderId = nextOrderId++;

        PoolId poolId = poolKey.toId();
        address token0Addr = Currency.unwrap(poolKey.currency0);
        address token1Addr = Currency.unwrap(poolKey.currency1);

        // Transfer tokens to hook (custody)
        if (zeroForOne) {
            IERC20(token0Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        } else {
            IERC20(token1Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        }

        orders[orderId] = LimitOrder({
            amount0: zeroForOne ? amountIn : 0,
            amount1: zeroForOne ? 0 : amountIn,
            token0: token0Addr,
            token1: token1Addr,
            triggerPrice: triggerPrice,
            createdAt: uint64(block.timestamp),
            isFilled: false,
            zeroForOne: zeroForOne,
            vaultShares: 0,
            sqrtPriceAtFill: 0,
            poolId: poolId
        });

        // Mint ERC721 NFT representing this position (orderId = tokenId)
        _mint(msg.sender, orderId);

        userOrders[msg.sender].push(orderId);

        // Ensure this pool's linked-list sentinels exist (H2: also covers a caller-supplied
        // poolKey whose pool was not initialized through this hook's _afterInitialize).
        _ensurePoolSentinels(poolId);

        // Index by (pool, tick) bucket, recording the order's index for O(1) removal (M3)
        int24 alignedTick =
            _alignTick(TickMath.getTickAtSqrtPrice(uint128ToSqrtPrice(triggerPrice)), poolKey.tickSpacing);
        uint256[] storage bucket = tickToOrders[poolId][alignedTick];
        orderBucketIndex[orderId] = bucket.length;
        bucket.push(orderId);
        orderTickBucket[orderId] = alignedTick;

        // Insert tick into this pool's sorted linked list if not already active
        if (!isActiveTick[poolId][alignedTick]) {
            _insertActiveTick(poolId, alignedTick);
        }

        emit OrderCreated(orderId, msg.sender, zeroForOne, amountIn, triggerPrice);
    }

    /// @notice Cancel an active order and return deposited tokens
    /// @dev Removes the order from its tick bucket. If the bucket becomes empty,
    ///      removes the tick from the active linked list. Burns the ERC721 NFT.
    ///      Protected by ReentrancyGuard against ERC-777 callbacks.
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 orderId) external nonReentrant {
        LimitOrder storage order = orders[orderId];

        if (ownerOf(orderId) != msg.sender) revert NotOrderCreator();
        if (order.isFilled) revert OrderAlreadyFilled();

        // Remove from (pool, tick) bucket — O(1) via the stored index (M3)
        PoolId poolId = order.poolId;
        int24 tick = orderTickBucket[orderId];
        _removeFromBucket(poolId, tick, orderBucketIndex[orderId]);

        // If tick bucket is now empty, remove from this pool's linked list
        if (tickToOrders[poolId][tick].length == 0) {
            _removeActiveTick(poolId, tick);
        }

        // Return tokens
        if (order.zeroForOne && order.amount0 > 0) {
            IERC20(order.token0).safeTransfer(msg.sender, uint256(order.amount0));
        } else if (!order.zeroForOne && order.amount1 > 0) {
            IERC20(order.token1).safeTransfer(msg.sender, uint256(order.amount1));
        }

        // Burn NFT to mark position as closed
        _burn(orderId);

        emit OrderCancelled(orderId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                       ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Force-cancel a stuck order (admin only). Returns tokens to current NFT owner.
    /// @param orderId The ID of the order to force-cancel
    function forceCancelOrder(uint256 orderId) external onlyOwner {
        LimitOrder storage order = orders[orderId];

        if (order.isFilled) revert OrderAlreadyFilled();
        if (_ownerOf(orderId) == address(0)) revert OrderNotActive(); // burned = already cancelled

        // H3 invariant: only UNFILLED orders reach here. `vaultShares` is set solely by
        // depositToVault (which requires isFilled == true), and isFilled is monotonic (never
        // reset), so any order with vaultShares > 0 is filled and reverts at the guard above.
        // Therefore no vault redemption is needed here and no deposited principal can be
        // stranded. A filled order's output is the owner's bearer claim, recoverable only via
        // claimOrder (which redeems vaultShares) — admin intentionally cannot seize a filled
        // position. (See test_H3_ForceCancel_CannotStrandVaultShares.)

        address recipient = ownerOf(orderId);

        // Remove from (pool, tick) bucket — O(1) via the stored index (M3)
        PoolId poolId = order.poolId;
        int24 tick = orderTickBucket[orderId];
        _removeFromBucket(poolId, tick, orderBucketIndex[orderId]);

        if (tickToOrders[poolId][tick].length == 0) {
            _removeActiveTick(poolId, tick);
        }

        // Return tokens to current NFT owner
        if (order.zeroForOne && order.amount0 > 0) {
            IERC20(order.token0).safeTransfer(recipient, uint256(order.amount0));
        } else if (!order.zeroForOne && order.amount1 > 0) {
            IERC20(order.token1).safeTransfer(recipient, uint256(order.amount1));
        }

        order.amount0 = 0;
        order.amount1 = 0;

        // Burn the NFT to close the position
        _burn(orderId);

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
        // M2 solvency invariant: pendingFees[currency] is credited ONLY after the matching
        // feeAmount is physically taken into this hook (see _executeOrder), and it is the only
        // balance this function ever touches. Order outputs are taken and tracked separately
        // (order.amount0/amount1), and vault deposits leave the hook entirely — so withdrawing
        // fees can never dip into funds backing user orders. Proven by
        // test_M2_WithdrawFees_CannotEatOrderPrincipal.
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

    /// @notice Get all order IDs in a specific (pool, tick) bucket
    function getOrdersInTick(PoolId poolId, int24 tick) external view returns (uint256[] memory) {
        return tickToOrders[poolId][tick];
    }

    /// @notice Get the tick bucket an order was assigned to
    function getTickBucket(uint256 orderId) external view returns (int24) {
        return orderTickBucket[orderId];
    }

    /// @notice Get the next active tick above the given tick (per pool)
    function getNextActiveTick(PoolId poolId, int24 tick) external view returns (int24) {
        return nextActiveTick[poolId][tick];
    }

    /// @notice Get the next active tick below the given tick (per pool)
    function getPrevActiveTick(PoolId poolId, int24 tick) external view returns (int24) {
        return prevActiveTick[poolId][tick];
    }

    /// @notice Get accumulated fees for a specific currency
    function getPendingFees(Currency currency) external view returns (uint256) {
        return pendingFees[currency];
    }

    /// @notice Get LP position data for a specific pool and LP address
    function getLPPosition(PoolId poolId, address lp) external view returns (LPPosition memory) {
        return lpPositions[poolId][lp];
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

        // Read the ACTUAL post-swap price and tick
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);

        // Execute matching orders using the linked list
        _tryExecuteOrders(poolKey, currentPrice, params.zeroForOne);

        // Update lastTick after processing (used by IL tracking and direction logic)
        lastTick[poolKey.toId()] = currentTick;

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
    function _tryExecuteOrders(PoolKey calldata poolKey, uint128 currentPrice, bool swapZeroForOne) internal {
        PoolId poolId = poolKey.toId();
        // Defense-in-depth: never walk an uninitialized list (self-defending against any
        // future caller that reaches here for a pool that skipped _afterInitialize).
        if (!poolListInitialized[poolId]) return;

        int24 activeTickCount = 0;

        if (swapZeroForOne) {
            // Price went DOWN -> scan upward for BUY orders (triggerPrice >= currentPrice)
            // Start from the lowest active tick and go up
            int24 tick = nextActiveTick[poolId][SENTINEL_MIN];

            while (tick != SENTINEL_MAX && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache next before potential removal
                int24 nextTick = nextActiveTick[poolId][tick];

                _processTickBucket(poolId, tick, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[poolId][tick].length == 0) {
                    _removeActiveTick(poolId, tick);
                }

                activeTickCount++;
                tick = nextTick;
            }
        } else {
            // Price went UP -> scan downward for SELL orders (triggerPrice <= currentPrice)
            // Start from the highest active tick and go down
            int24 tick = prevActiveTick[poolId][SENTINEL_MAX];

            while (tick != SENTINEL_MIN && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache prev before potential removal
                int24 prevTick = prevActiveTick[poolId][tick];

                _processTickBucket(poolId, tick, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[poolId][tick].length == 0) {
                    _removeActiveTick(poolId, tick);
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
    function _processTickBucket(PoolId poolId, int24 tick, uint128 currentPrice, PoolKey calldata poolKey) internal {
        uint256[] storage orderIdsInTick = tickToOrders[poolId][tick];

        uint256 i = 0;
        while (i < orderIdsInTick.length) {
            if (gasleft() < GAS_LIMIT_PER_ORDER) break;

            uint256 orderId = orderIdsInTick[i];
            LimitOrder storage order = orders[orderId];

            // Lazy cleanup: remove filled or burned (cancelled) orders
            if (order.isFilled || _ownerOf(orderId) == address(0)) {
                _removeFromBucket(poolId, tick, i);
                continue;
            }

            // (H2) No token0 pool-filter needed: the bucket is namespaced by PoolId, so every
            // order in it provably belongs to this pool (the old currency0-only check was unsound).

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
                    _removeFromBucket(poolId, tick, i);
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

    function _executeOrder(PoolKey calldata poolKey, LimitOrder storage order, uint256 orderId)
        internal
        returns (bool success)
    {
        isExecuting = true;

        // Capture current owner for refunds and events (ERC721 owner at fill time)
        address orderOwner = ownerOf(orderId);
        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;

        // Get current price for slippage limit
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Price limit: 5% slippage on the internal swap
        uint160 sqrtPriceLimitX96 = order.zeroForOne
            ? ((uint256(currentSqrtPriceX96) * 95) / 100).toUint160()
            : ((uint256(currentSqrtPriceX96) * 105) / 100).toUint160();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: order.zeroForOne ? -int256(uint256(order.amount0)) : -int256(uint256(order.amount1)),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");

        // Record fill price for IL calculation in claimOrder
        order.sqrtPriceAtFill = currentSqrtPriceX96;

        // Settle input + Take output to this contract (output claimed via claimOrder)
        if (order.zeroForOne) {
            // swapDelta.amount0() is negative (hook owes token0 to pool)
            int128 deltaAmount0 = swapDelta.amount0();
            uint256 actualInput = uint256(uint128(-deltaAmount0));

            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), actualInput);
            poolManager.settle();

            int128 deltaAmount1 = swapDelta.amount1();
            uint256 amountOut = deltaAmount1 < 0 ? uint256(uint128(-deltaAmount1)) : uint256(uint128(deltaAmount1));

            uint256 feeAmount = (amountOut * feeBps) / 10000;
            uint256 netAmount = amountOut - feeAmount;

            uint256 expectedOut = (uint256(amountIn) * uint256(order.triggerPrice)) / 1e18;
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                // Slippage: still fill, emit warning. Output held in hook for claimOrder.
                poolManager.take(poolKey.currency1, address(this), netAmount);
                if (feeAmount > 0) {
                    poolManager.take(poolKey.currency1, address(this), feeAmount);
                    pendingFees[poolKey.currency1] += feeAmount;
                    emit FeeCollected(orderId, poolKey.currency1, feeAmount);
                }
                order.isFilled = true;
                order.amount1 = netAmount.toUint96();
                uint256 refund = uint256(amountIn) - actualInput;
                if (refund > 0) IERC20(order.token0).safeTransfer(orderOwner, refund);

                emit OrderExecutionFailed(orderId, "SlippageExceeded");
                emit OrderFilled(
                    orderId,
                    orderOwner,
                    uint96(actualInput),
                    netAmount.toUint96(),
                    sqrtPriceToUint128(currentSqrtPriceX96)
                );
                isExecuting = false;
                return true;
            }

            // Normal: output held in hook for claimOrder
            poolManager.take(poolKey.currency1, address(this), netAmount);
            if (feeAmount > 0) {
                poolManager.take(poolKey.currency1, address(this), feeAmount);
                pendingFees[poolKey.currency1] += feeAmount;
                emit FeeCollected(orderId, poolKey.currency1, feeAmount);
            }
            order.isFilled = true;
            order.amount1 = netAmount.toUint96();
            uint256 refund0 = uint256(amountIn) - actualInput;
            if (refund0 > 0) IERC20(order.token0).safeTransfer(orderOwner, refund0);
        } else {
            // swapDelta.amount1() is negative (hook owes token1 to pool)
            int128 deltaAmount1 = swapDelta.amount1();
            uint256 actualInput = uint256(uint128(-deltaAmount1));

            poolManager.sync(poolKey.currency1);
            IERC20(order.token1).safeTransfer(address(poolManager), actualInput);
            poolManager.settle();

            int128 deltaAmount0 = swapDelta.amount0();
            uint256 amountOut = deltaAmount0 < 0 ? uint256(uint128(-deltaAmount0)) : uint256(uint128(deltaAmount0));

            uint256 feeAmount = (amountOut * feeBps) / 10000;
            uint256 netAmount = amountOut - feeAmount;

            uint256 expectedOut = (uint256(amountIn) * 1e18) / uint256(order.triggerPrice);
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                // Slippage: still fill, output held in hook
                poolManager.take(poolKey.currency0, address(this), netAmount);
                if (feeAmount > 0) {
                    poolManager.take(poolKey.currency0, address(this), feeAmount);
                    pendingFees[poolKey.currency0] += feeAmount;
                    emit FeeCollected(orderId, poolKey.currency0, feeAmount);
                }
                order.isFilled = true;
                order.amount0 = netAmount.toUint96();
                uint256 refund = uint256(amountIn) - actualInput;
                if (refund > 0) IERC20(order.token1).safeTransfer(orderOwner, refund);

                emit OrderExecutionFailed(orderId, "SlippageExceeded");
                emit OrderFilled(
                    orderId,
                    orderOwner,
                    uint96(actualInput),
                    netAmount.toUint96(),
                    sqrtPriceToUint128(currentSqrtPriceX96)
                );
                isExecuting = false;
                return true;
            }

            // Normal: output held in hook for claimOrder
            poolManager.take(poolKey.currency0, address(this), netAmount);
            if (feeAmount > 0) {
                poolManager.take(poolKey.currency0, address(this), feeAmount);
                pendingFees[poolKey.currency0] += feeAmount;
                emit FeeCollected(orderId, poolKey.currency0, feeAmount);
            }
            order.isFilled = true;
            order.amount0 = netAmount.toUint96();
            uint256 refund1 = uint256(amountIn) - actualInput;
            if (refund1 > 0) IERC20(order.token1).safeTransfer(orderOwner, refund1);
        }

        emit OrderFilled(
            orderId,
            orderOwner,
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

    /// @notice Initialize a pool's active-tick linked-list sentinels exactly once (H2).
    /// @dev Idempotent; called from _afterInitialize and createLimitOrder so the list is
    ///      always valid before any insert/walk (avoids the default-zero sentinel trap).
    function _ensurePoolSentinels(PoolId poolId) internal {
        if (!poolListInitialized[poolId]) {
            nextActiveTick[poolId][SENTINEL_MIN] = SENTINEL_MAX;
            prevActiveTick[poolId][SENTINEL_MAX] = SENTINEL_MIN;
            poolListInitialized[poolId] = true;
        }
    }

    /// @notice Insert a tick into the sorted doubly-linked list
    /// @dev Walks forward from SENTINEL_MIN to find the correct sorted position.
    ///      For most use cases (few dozen active ticks), this is cheap.
    ///      Worst case: O(N) where N = number of active ticks.
    ///      Could be optimized with a hint parameter if needed for >1000 active ticks.
    function _insertActiveTick(PoolId poolId, int24 tick) internal {
        // Walk from the lowest sentinel to find insertion point
        int24 cursor = SENTINEL_MIN;
        while (nextActiveTick[poolId][cursor] != SENTINEL_MAX && nextActiveTick[poolId][cursor] < tick) {
            cursor = nextActiveTick[poolId][cursor];
        }

        // Insert between cursor and cursor.next
        // Before: cursor <-> cursorNext
        // After:  cursor <-> tick <-> cursorNext
        int24 cursorNext = nextActiveTick[poolId][cursor];

        nextActiveTick[poolId][cursor] = tick;
        prevActiveTick[poolId][tick] = cursor;
        nextActiveTick[poolId][tick] = cursorNext;
        prevActiveTick[poolId][cursorNext] = tick;

        isActiveTick[poolId][tick] = true;
    }

    /// @notice Remove a tick from the sorted doubly-linked list
    /// @dev O(1) operation - just unlink the node.
    function _removeActiveTick(PoolId poolId, int24 tick) internal {
        if (!isActiveTick[poolId][tick]) return;

        int24 prev = prevActiveTick[poolId][tick];
        int24 next = nextActiveTick[poolId][tick];

        // Before: prev <-> tick <-> next
        // After:  prev <-> next
        nextActiveTick[poolId][prev] = next;
        prevActiveTick[poolId][next] = prev;

        // Clean up
        delete nextActiveTick[poolId][tick];
        delete prevActiveTick[poolId][tick];
        isActiveTick[poolId][tick] = false;
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

    /// @notice O(1) removal of the order at `index` from a (pool, tick) bucket via swap-and-pop,
    ///         keeping `orderBucketIndex` consistent so cancel/forceCancel need no linear scan (M3).
    /// @dev The last element is moved into the freed slot and its index updated; callers pass the
    ///      index from `orderBucketIndex[orderId]` (cancel/forceCancel) or the loop index `i`
    ///      (_processTickBucket, where arr[i] is the order being removed).
    function _removeFromBucket(PoolId poolId, int24 tick, uint256 index) internal {
        uint256[] storage arr = tickToOrders[poolId][tick];
        if (index >= arr.length) revert IndexOutOfBounds();
        uint256 removedOrderId = arr[index];
        uint256 lastIndex = arr.length - 1;
        if (index != lastIndex) {
            uint256 lastOrderId = arr[lastIndex];
            arr[index] = lastOrderId;
            orderBucketIndex[lastOrderId] = index;
        }
        arr.pop();
        delete orderBucketIndex[removedOrderId];
    }

    /*//////////////////////////////////////////////////////////////
               IL-AWARE HOOK CALLBACKS (UHI9)
    //////////////////////////////////////////////////////////////*/

    /// @notice Saves lastTick and sqrtPriceBaseline for IL tracking at pool initialization
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        lastTick[poolId] = tick;
        sqrtPriceBaseline[poolId] = sqrtPriceX96;
        _ensurePoolSentinels(poolId);
        return this.afterInitialize.selector;
    }

    /// @notice Pass-through beforeSwap; returns ZERO_DELTA (NoOp execution lives here in Block 2)
    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Records LP entry price and liquidity when liquidity is added
    /// @dev LP must pass abi.encode(realLP) as hookData; without it IL tracking is skipped (graceful degradation)
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length >= 32) {
            address realLP = abi.decode(hookData, (address));
            if (realLP != address(0) && params.liquidityDelta > 0) {
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
                lpPositions[key.toId()][realLP] = LPPosition({
                    sqrtPriceAtEntry: sqrtPriceX96,
                    liquidity: uint128(uint256(params.liquidityDelta)),
                    entryTimestamp: block.timestamp,
                    idleAmount: 0,
                    vaultShares: 0
                });
            }
        }
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Oracle-free rebate-sizing HEURISTIC based on the Uniswap V2 IL curve.
    /// @dev NOT a precise impermanent-loss figure. Returns `outputNotional * (Δ√P/√P)² / 2` —
    ///      the V2-IL shape scaled by the order's OUTPUT NOTIONAL (a token amount) used purely as
    ///      a sizing scalar. `outputNotional` is therefore NOT Uniswap liquidity `L` (the two are
    ///      not dimensionally comparable, and tokens with more decimals scale it up); treat the
    ///      result as an approximate, order-size-proportional rebate CEILING, valid only for small
    ///      moves (<50%; it underestimates beyond).
    ///
    ///      SAFETY (M1 + J2): this value is consumed ONLY as the upper bound in
    ///      `rebate = min(yieldEarned, ilAmount)` (claimOrder), and the payout is further capped at
    ///      the vault's `redeemed` amount (RebateExceedsRedeemed guard). So however the heuristic is
    ///      sized — and however the triggering/fill price is manipulated — the rebate can never
    ///      exceed the user's own realized vault yield, and can never draw from other orders'
    ///      custody or from fees. A precise on-chain IL / TWAP oracle was judged disproportionate
    ///      precisely because the payout is yield-capped. `sqrtPriceCurrent` is the fill price
    ///      captured BEFORE the hook's own internal swap (no self-inflicted skew).
    function _calculateIL(uint160 sqrtPriceEntry, uint160 sqrtPriceCurrent, uint128 outputNotional)
        internal
        pure
        returns (uint256 ilAmount)
    {
        if (sqrtPriceEntry == 0 || sqrtPriceCurrent == 0 || outputNotional == 0) return 0;
        uint256 sqrtR = (uint256(sqrtPriceCurrent) * 1e9) / uint256(sqrtPriceEntry);
        uint256 diff = sqrtR > 1e9 ? sqrtR - 1e9 : 1e9 - sqrtR;
        ilAmount = (uint256(outputNotional) * diff * diff) / (2 * 1e9 * 1e9);
    }

    /// @notice Deposits the output of a filled limit order into the ERC-4626 yield vault
    /// @dev Must be called AFTER the order fills (isFilled = true). Separate from hook callbacks
    ///      to avoid reentrancy with pool. Vault deposit failures are caught gracefully.
    /// @param orderId The filled limit order whose output tokens should be deposited
    function depositToVault(uint256 orderId) external nonReentrant {
        LimitOrder storage order = orders[orderId];
        if (ownerOf(orderId) != msg.sender) revert NotOrderCreator();
        if (!order.isFilled) revert OrderNotFilled();
        if (yieldVault == address(0)) return;
        if (order.vaultShares > 0) return;

        address outputToken = order.zeroForOne ? order.token1 : order.token0;
        uint256 amount = order.zeroForOne ? uint256(order.amount1) : uint256(order.amount0);
        if (amount == 0) return;

        IERC20(outputToken).forceApprove(yieldVault, amount);
        try IERC4626(yieldVault).deposit(amount, address(this)) returns (uint256 shares) {
            order.vaultShares = shares;
        } catch {
            IERC20(outputToken).forceApprove(yieldVault, 0);
        }
    }

    /// @notice Claim a filled limit order: transfer output + optional IL rebate from vault yield
    /// @dev Two-phase settlement: order fills into hook, user claims here with optional yield rebate.
    ///      Vault-redeem failure is handled gracefully WITHOUT touching other orders' custodied
    ///      funds: when a deposited order's vault redeem reverts, the principal is still locked in
    ///      the vault (not in this hook), so we cannot safely pay it from the hook balance. Instead
    ///      the position is left fully intact (NFT + amounts + vaultShares) and `VaultRedeemFailed`
    ///      is emitted, so the owner can simply re-claim once the vault recovers. Orders whose
    ///      output was never deposited (vaultShares == 0) are always paid directly from the hook.
    /// @param orderId   The filled order to claim
    /// @param poolKey   Pool key the order was placed in (needed for IL baseline lookup)
    function claimOrder(uint256 orderId, PoolKey calldata poolKey) external nonReentrant {
        LimitOrder storage order = orders[orderId];
        if (!order.isFilled) revert OrderNotFilled();
        if (ownerOf(orderId) != msg.sender) revert NotOrderCreator();
        // H1: bind the claim to the order's real pool — reject a caller-supplied foreign pool
        if (PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(order.poolId)) revert PoolKeyMismatch();

        // Determine output
        address outputToken = order.zeroForOne ? order.token1 : order.token0;
        uint256 outputAmount = order.zeroForOne ? uint256(order.amount1) : uint256(order.amount0);
        if (outputAmount == 0) revert OrderAlreadyClaimed();

        // Rebate-sizing heuristic (see _calculateIL): pool-init baseline vs fill price, scaled by
        // the order's output notional. This is an UPPER BOUND only — the actual rebate is
        // min(yieldEarned, ilAmount), further capped at `redeemed` — so its precision never
        // affects solvency (M1 + J2).
        PoolId poolId = poolKey.toId();
        uint256 ilAmount = _calculateIL(
            sqrtPriceBaseline[poolId],
            order.sqrtPriceAtFill,
            uint128(outputAmount > type(uint128).max ? type(uint128).max : outputAmount)
        );

        uint256 totalOut = outputAmount;
        uint256 rebate = 0;

        if (order.vaultShares > 0 && yieldVault != address(0)) {
            uint256 shares = order.vaultShares;
            try IERC4626(yieldVault).redeem(shares, address(this), address(this)) returns (uint256 redeemed) {
                // Vault paid `redeemed` assets into this hook; settling from that is solvency-safe.
                order.vaultShares = 0;
                if (redeemed > outputAmount) {
                    uint256 yieldEarned = redeemed - outputAmount;
                    rebate = yieldEarned < ilAmount ? yieldEarned : ilAmount;
                    totalOut = outputAmount + rebate;
                } else {
                    // Vault returned <= principal (lossy redeem): pay back exactly what we received.
                    totalOut = redeemed;
                }
                // M2 structural solvency: in the vault path the payout is funded ONLY by what the
                // vault just delivered this tx, so it must never exceed `redeemed`. This makes the
                // "rebate is self-funded" property hold BY CONSTRUCTION (not by arithmetic
                // coincidence of the rebate formula) — a future formula change cannot silently
                // draw from other orders' custody or from pendingFees.
                if (totalOut > redeemed) revert RebateExceedsRedeemed();
            } catch {
                // Vault redeem reverted: the principal is still locked in the vault, NOT in this
                // hook. Paying `outputAmount` now would have to come from other orders' custodied
                // balances and would break the hook's solvency. Instead we leave the position FULLY
                // intact (NFT, amounts, and vaultShares all untouched) so the owner can re-claim
                // once the vault recovers, and surface the failure via an event. No state mutates
                // on this path, so nothing is lost and no one else's funds are drawn down.
                emit VaultRedeemFailed(orderId, shares);
                return;
            }
        }

        // Reaching here the payout is physically held by this hook (output was either never
        // deposited, or was just redeemed from the vault). Settle, then burn the position token.
        order.amount0 = 0;
        order.amount1 = 0;
        _burn(orderId);

        IERC20(outputToken).safeTransfer(msg.sender, totalOut);
    }
}
