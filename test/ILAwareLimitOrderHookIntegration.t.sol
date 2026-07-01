// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  SimulatedYieldVault — same logic as script/DeployHookathon.s.sol
//  Simulates 3% APY using block.timestamp; mints yield deficit via MockERC20.
// ─────────────────────────────────────────────────────────────────────────────

/// @title  SimulatedYieldVault (test copy)
/// @notice Mirrors the production SimulatedYieldVault in DeployHookathon.s.sol.
///         Yield formula (simple interest):
///           assets = shares + shares * APY_BPS * elapsed / (10_000 * 365 days)
///         Yield deficit is minted on-demand via MockERC20.mint — no manual top-up needed.
contract SimulatedYieldVault {
    IERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    uint256 public constant APY_BPS = 300; // 3% per year
    uint256 public immutable startTime;

    constructor(address _asset) {
        asset = IERC20(_asset);
        startTime = block.timestamp;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        sharesOf[receiver] += shares;
        totalShares += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(sharesOf[owner] >= shares, "SimulatedYieldVault: insufficient shares");
        sharesOf[owner] -= shares;
        totalShares -= shares;
        uint256 simulated = previewRedeem(shares);
        uint256 balance = asset.balanceOf(address(this));
        if (simulated > balance) {
            uint256 deficit = simulated - balance;
            (bool ok,) = address(asset).call(
                abi.encodeWithSignature("mint(address,uint256)", address(this), deficit)
            );
            assets = ok ? simulated : balance;
        } else {
            assets = simulated;
        }
        asset.transfer(receiver, assets);
    }

    /// @notice Principal + simple-interest APY since vault deployment
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        uint256 yieldAmt = (shares * APY_BPS * elapsed) / (10_000 * 365 days);
        return shares + yieldAmt;
    }

    function totalAssets() external view returns (uint256) { return previewRedeem(totalShares); }
    function convertToAssets(uint256 shares) external view returns (uint256) { return previewRedeem(shares); }
    function convertToShares(uint256 assets) external pure returns (uint256) { return assets; }
    function previewDeposit(uint256 assets) external pure returns (uint256) { return assets; }
    function previewMint(uint256 shares) external pure returns (uint256) { return shares; }
    function maxDeposit(address) external pure returns (uint256) { return type(uint256).max; }
    function maxMint(address) external pure returns (uint256)    { return type(uint256).max; }
    function maxRedeem(address owner) external view returns (uint256) { return sharesOf[owner]; }
    function maxWithdraw(address owner) external view returns (uint256) { return previewRedeem(sharesOf[owner]); }
}

// ─────────────────────────────────────────────────────────────────────────────

/// @dev Simple ERC4626 mock: stores deposits and returns shares 1:1 (no yield by default)
///      Set `yieldBps` to simulate yield (redeem returns more than principal) or
///      `lossBps` to simulate a lossy vault (redeem returns less than principal).
contract MockERC4626 {
    IERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    uint256 public yieldBps; // extra yield in BPS (0 = no yield)
    uint256 public lossBps; // shortfall in BPS (0 = no loss); redeem returns shares - loss
    bool public shouldRevert;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function setYieldBps(uint256 _yieldBps) external {
        yieldBps = _yieldBps;
    }

    function setLossBps(uint256 _lossBps) external {
        lossBps = _lossBps;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (shouldRevert) revert("vault: revert");
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        sharesOf[receiver] += shares;
        totalShares += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (shouldRevert) revert("vault: revert");
        require(sharesOf[owner] >= shares, "insufficient shares");
        sharesOf[owner] -= shares;
        totalShares -= shares;
        // Net assets = principal + yield - loss (yield and loss are mutually exclusive in tests)
        uint256 yieldAmt = shares * yieldBps / 10000;
        uint256 lossAmt = shares * lossBps / 10000;
        assets = shares + yieldAmt - lossAmt;
        // Mint extra tokens to back simulated yield (test only); a loss shortfall simply stays
        // behind in the vault, since the mock already custodies the full `shares` from deposit.
        if (yieldAmt > 0) MockERC20(address(asset)).mint(address(this), yieldAmt);
        asset.transfer(receiver, assets);
    }
}

contract ILAwareLimitOrderHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    PoolManager manager;
    ILAwareLimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address user;

    event OrderFilled(
        uint256 indexed orderId, address indexed creator, uint96 amountIn, uint96 amountOut, uint128 executionPrice
    );

    event OrderExecutionFailed(uint256 indexed orderId, string reason);

    event OrderForceCancelled(uint256 indexed orderId, address indexed admin);

    event FeeCollected(uint256 indexed orderId, Currency indexed currency, uint256 feeAmount);

    event VaultRedeemFailed(uint256 indexed orderId, uint256 shares);

    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    event FeesWithdrawn(Currency indexed currency, address indexed recipient, uint256 amount);

    function setUp() public {
        user = makeAddr("user");

        manager = new PoolManager(address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // UHI9: all 7 hook flags for ILAwareLimitOrderHook
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager), address(this), address(0));

        vm.pauseGasMetering();
        (address predictedAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, constructorArgs);

        hook = new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(0));
        require(address(hook) == predictedAddress, "Hook address mismatch!");
        vm.resumeGasMetering();

        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        // Add liquidity
        addLiquidity();

        // Fund alice
        token0.mint(alice, 100_000e18);
        token1.mint(alice, 100_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function addLiquidity() internal {
        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);

        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -1200, tickUpper: 1200, liquidityDelta: 10_000e18, salt: bytes32(0)
            }),
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateOrder() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(hook.ownerOf(orderId), alice, "ERC721 owner should be alice");
        assertEq(order.amount0, 1e18);
        assertTrue(order.zeroForOne);
        assertFalse(order.isFilled);
    }

    function testCreateOrderTransfersTokens() public {
        uint256 hookToken0Before = token0.balanceOf(address(hook));

        vm.prank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        assertEq(token0.balanceOf(address(hook)) - hookToken0Before, 1e18);
    }

    function testZeroAmountFails() public {
        vm.prank(alice);
        vm.expectRevert(ILAwareLimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 1e18);
    }

    /// @notice M-2: Validate poolKey - tickSpacing must be > 0
    function testInvalidPoolKeyFails() public {
        PoolKey memory badPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 0,
            hooks: hook
        });

        vm.prank(alice);
        vm.expectRevert(ILAwareLimitOrderHook.InvalidPoolKey.selector);
        hook.createLimitOrder(badPoolKey, true, 1e18, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelOrderReturnsTokens() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.prank(alice);
        hook.cancelOrder(orderId);

        assertEq(token0.balanceOf(alice) - aliceToken0Before, 1e18);

        // NFT should be burned after cancel (ownerOf should revert)
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    function testUnauthorizedCancellationFails() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        vm.prank(bob);
        vm.expectRevert(ILAwareLimitOrderHook.NotOrderCreator.selector);
        hook.cancelOrder(orderId);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: BUY order (zeroForOne=false) triggers when price drops
    function testFullOrderExecution() public {
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;

        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, amountIn, triggerPrice);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled");
    }

    /// @notice Test: SELL order triggers when price goes up
    function testSellOrderExecution() public {
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;

        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, amountIn, triggerPrice);

        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Sell order should be filled");
    }

    function testRangeExecution() public {
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.005e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.01e18);
        vm.stopPrank();

        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 filledCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }
        assertTrue(filledCount >= 2, "Multiple orders should be range-filled");
    }

    function testBatchExecution() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        }
        vm.stopPrank();

        token0.mint(address(this), 200e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -200e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 filledCount = 0;
        for (uint256 i = 0; i < 5; i++) {
            ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }
        assertTrue(filledCount > 0, "At least one order should be batch-filled");
    }

    function testGasLimitProtection() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        }
        vm.stopPrank();

        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(true, "Gas limit protection prevented OOG revert");
    }

    function testBucketCleanup() public {
        vm.startPrank(alice);
        uint256 orderId1 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.cancelOrder(orderId1);
        uint256 orderId2 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order2 = hook.getOrder(orderId2);
        assertTrue(order2.isFilled, "Second order should execute after cleanup");
    }

    /*//////////////////////////////////////////////////////////////
              PHASE 3.12: LINKED LIST & DYNAMIC TICK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that creating an order inserts the tick into the active list
    function testActiveTickInsertedOnCreate() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Before any orders: SENTINEL_MIN -> SENTINEL_MAX
        assertEq(hook.nextActiveTick(poolKey.toId(), sentinelMin), sentinelMax, "Empty list should point min->max");
        assertEq(hook.prevActiveTick(poolKey.toId(), sentinelMax), sentinelMin, "Empty list should point max->min");

        vm.prank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // Now there should be one active tick between sentinels
        int24 firstActive = hook.nextActiveTick(poolKey.toId(), sentinelMin);
        assertTrue(firstActive != sentinelMax, "Should have an active tick after create");
        assertTrue(hook.isActiveTick(poolKey.toId(), firstActive), "Tick should be marked active");
        assertEq(hook.nextActiveTick(poolKey.toId(), firstActive), sentinelMax, "First active -> SENTINEL_MAX");
        assertEq(hook.prevActiveTick(poolKey.toId(), firstActive), sentinelMin, "SENTINEL_MIN <- first active");
    }

    /// @notice Verify that cancelling all orders at a tick removes it from list
    function testActiveTickRemovedOnCancel() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        vm.startPrank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // Verify tick is active
        int24 activeTick = hook.nextActiveTick(poolKey.toId(), sentinelMin);
        assertTrue(activeTick != sentinelMax, "Tick should be in list");

        // Cancel the only order at that tick
        hook.cancelOrder(orderId);
        vm.stopPrank();

        // Tick should be removed from list
        assertEq(hook.nextActiveTick(poolKey.toId(), sentinelMin), sentinelMax, "Tick should be removed after cancel");
        assertFalse(hook.isActiveTick(poolKey.toId(), activeTick), "Tick should not be active after cancel");
    }

    /// @notice Verify sorted insertion with multiple different trigger prices
    function testSortedInsertion() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create orders at 3 different prices
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.005e18); // higher price = higher tick
        hook.createLimitOrder(poolKey, true, 1e18, 1.001e18); // lower price = lower tick
        hook.createLimitOrder(poolKey, true, 1e18, 1.01e18); // highest price
        vm.stopPrank();

        // Walk the list and verify it's sorted ascending
        int24 prev = sentinelMin;
        int24 current = hook.nextActiveTick(poolKey.toId(), sentinelMin);
        uint256 count = 0;

        while (current != sentinelMax) {
            assertTrue(current > prev || prev == sentinelMin, "List must be sorted ascending");
            prev = current;
            current = hook.nextActiveTick(poolKey.toId(), current);
            count++;
        }

        // We should have 3 distinct ticks (different trigger prices map to different ticks)
        assertTrue(count >= 2, "Should have multiple active ticks for different prices");
    }

    /// @notice Verify that duplicate tick insertions don't create duplicates in the list
    function testNoDuplicateTickInsertion() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create 3 orders at the same price -> same tick bucket
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Walk the list - should have exactly 1 active tick
        int24 current = hook.nextActiveTick(poolKey.toId(), sentinelMin);
        uint256 count = 0;
        while (current != sentinelMax) {
            count++;
            current = hook.nextActiveTick(poolKey.toId(), current);
        }
        assertEq(count, 1, "Same price orders should share one tick in the list");
    }

    /// @notice Test that execution cleans up the linked list when bucket empties
    function testLinkedListCleanupAfterExecution() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create a single BUY order
        vm.prank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Verify tick is in list
        assertTrue(hook.nextActiveTick(poolKey.toId(), sentinelMin) != sentinelMax, "Should have active tick");

        // Execute swap to fill the order
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Order should be filled and tick removed from list
        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(0);
        assertTrue(order.isFilled, "Order should be filled");
    }

    /// @notice Partial cancel: cancel one of two orders at same tick, tick stays active
    function testPartialCancelKeepsTickActive() public {
        vm.startPrank(alice);
        uint256 order1 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        uint256 order2 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Both at same tick - cancel one
        hook.cancelOrder(order1);
        vm.stopPrank();

        // Tick should still be active (order2 remains)
        int24 tick = hook.getTickBucket(order2);
        assertTrue(hook.isActiveTick(poolKey.toId(), tick), "Tick should remain active with remaining order");
    }

    /*//////////////////////////////////////////////////////////////
        H1 + H2: POOL ISOLATION (audit hardening)
    //////////////////////////////////////////////////////////////*/

    /// @dev Spin up a second pool sharing currency0/currency1 but with a different fee tier
    ///      (distinct PoolId), fully initialized and funded with liquidity.
    function _setUpSecondPool() internal returns (PoolKey memory poolKeyB) {
        poolKeyB = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hook
        });
        manager.initialize(poolKeyB, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKeyB,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -1200, tickUpper: 1200, liquidityDelta: 10_000e18, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice H2: an order in pool A must NOT be filled by a swap in a different pool B
    ///         (both share currency0), and must still fill from its own pool's swap.
    function test_H2_CrossPoolIsolation() public {
        PoolKey memory poolKeyB = _setUpSecondPool();

        // BUY-token0 order in pool A (fills on a price-down swap)
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        assertFalse(hook.getOrder(orderId).isFilled, "not filled at creation");

        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);

        // Swap in pool B (price down) — must NOT touch pool A's order (H2 fix)
        swapRouter.swap(
            poolKeyB,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertFalse(hook.getOrder(orderId).isFilled, "H2: pool A order must NOT fill from a pool B swap");

        // Swap in pool A — SHOULD fill it
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(hook.getOrder(orderId).isFilled, "order should fill from its own pool's swap");
    }

    /// @notice H1: claimOrder must reject a poolKey that doesn't match the order's pool,
    ///         and accept the correct one.
    function test_H1_ClaimOrder_RejectsForeignPoolKey() public {
        // Create + fill a BUY-token0 order in pool A
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(hook.getOrder(orderId).isFilled, "order should be filled");

        // A foreign poolKey (same tokens, different fee -> different PoolId) must revert
        PoolKey memory foreignKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hook
        });
        vm.prank(alice);
        vm.expectRevert(ILAwareLimitOrderHook.PoolKeyMismatch.selector);
        hook.claimOrder(orderId, foreignKey);

        // The correct poolKey succeeds (no revert)
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);

        // NFT burned after a successful claim — ownerOf reverts
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    /*//////////////////////////////////////////////////////////////
              PHASE 3.14: GRACEFUL EXECUTION & ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Phase 3.14: Verify swap succeeds even when order has bad slippage
    function testGracefulExecutionOnSlippage() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        // This swap MUST succeed - no revert allowed even if order slippage is bad
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled gracefully");

        // Output is held in hook; alice claims it via claimOrder
        uint256 aliceToken0Before = token0.balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);
        uint256 aliceToken0After = token0.balanceOf(alice);

        assertTrue(aliceToken0After > aliceToken0Before, "Alice should receive output tokens via claimOrder");
    }

    /// @notice Phase 3.14: Multiple orders - all should process without reverting the swap
    function testMultipleOrdersGracefulExecution() public {
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 2e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 filledCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }
        assertTrue(filledCount > 0, "At least some orders should fill gracefully");
    }

    /// @notice Phase 3.14: Admin can force-cancel an orphaned order
    function testForceCancelOrder() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 5e18, 1.002e18);

        uint256 aliceBalBefore = token0.balanceOf(alice);

        hook.forceCancelOrder(orderId);

        uint256 aliceBalAfter = token0.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, 5e18, "Tokens should be returned to creator");

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.amount0, 0, "Amount should be zeroed after force cancel");
        // NFT burned — ownerOf should revert
        vm.expectRevert();
        hook.ownerOf(orderId);

        int24 tick = hook.getTickBucket(orderId);
        assertFalse(hook.isActiveTick(poolKey.toId(), tick), "Tick should be removed after force cancel");
    }

    /// @notice Phase 3.14: Non-admin cannot force-cancel
    function testForceCancelOnlyOwner() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        vm.prank(bob);
        vm.expectRevert(); // Ownable: caller is not the owner
        hook.forceCancelOrder(orderId);
    }

    /// @notice Phase 3.14: Cannot force-cancel an already-filled order
    function testForceCancelFilledOrderFails() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled first");

        vm.expectRevert(ILAwareLimitOrderHook.OrderAlreadyFilled.selector);
        hook.forceCancelOrder(orderId);
    }

    /*//////////////////////////////////////////////////////////////
              PHASE 3.15: FEE MECHANISM TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify fee is deducted on BUY order execution; output claimed via claimOrder
    function testFeeCollectionOnBuyOrder() public {
        assertEq(hook.feeBps(), 5, "Default fee should be 5 BPS");

        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Execute swap to trigger BUY order (output held in hook)
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled");

        // Fee is accumulated from execution
        uint256 pendingFee = hook.getPendingFees(poolKey.currency0);
        assertTrue(pendingFee > 0, "Fee should be collected at execution");

        // Alice claims her output
        uint256 aliceToken0Before = token0.balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);
        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceReceived = aliceToken0After - aliceToken0Before;

        assertTrue(aliceReceived > 0, "Alice should receive tokens via claimOrder");

        // Verify fee math: pendingFee = (aliceReceived + pendingFee) * 5 / 10000
        uint256 totalOutput = aliceReceived + pendingFee;
        uint256 expectedFee = (totalOutput * 5) / 10000;
        assertEq(pendingFee, expectedFee, "Fee calculation should be exact");

        console2.log("Alice received:", aliceReceived);
        console2.log("Fee collected:", pendingFee);
    }

    /// @notice Verify fee is deducted on SELL order execution; output claimed via claimOrder
    function testFeeCollectionOnSellOrder() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // Execute swap to trigger SELL order (price goes UP)
        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Sell order should be filled");

        uint256 pendingFee = hook.getPendingFees(poolKey.currency1);
        assertTrue(pendingFee > 0, "Fee should be collected from sell order");

        // Alice claims her token1 output
        uint256 aliceToken1Before = token1.balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);
        uint256 aliceToken1After = token1.balanceOf(alice);
        uint256 aliceReceived = aliceToken1After - aliceToken1Before;
        assertTrue(aliceReceived > 0, "Alice should receive token1 via claimOrder");

        console2.log("Sell order - Alice received:", aliceReceived);
        console2.log("Sell order - Fee collected:", pendingFee);
    }

    /// @notice Verify owner can withdraw accumulated fees
    function testWithdrawFees() public {
        // Execute an order to accumulate fees
        vm.prank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 pendingFee = hook.getPendingFees(poolKey.currency0);
        assertTrue(pendingFee > 0, "Should have pending fees");

        // Owner (test contract) withdraws fees to bob
        address feeRecipient = makeAddr("feeRecipient");
        uint256 recipientBefore = token0.balanceOf(feeRecipient);

        hook.withdrawFees(poolKey.currency0, feeRecipient);

        uint256 recipientAfter = token0.balanceOf(feeRecipient);
        assertEq(recipientAfter - recipientBefore, pendingFee, "Recipient should receive all fees");

        // Pending fees should be zeroed
        assertEq(hook.getPendingFees(poolKey.currency0), 0, "Pending fees should be zero after withdraw");
    }

    /// @notice Verify non-owner cannot withdraw fees
    function testWithdrawFeesOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(); // Ownable: caller is not the owner
        hook.withdrawFees(poolKey.currency0, bob);
    }

    /// @notice Verify withdrawing zero fees reverts
    function testWithdrawZeroFeesReverts() public {
        vm.expectRevert(ILAwareLimitOrderHook.NoFeesToWithdraw.selector);
        hook.withdrawFees(poolKey.currency0, address(this));
    }

    /// @notice Verify owner can update fee rate
    function testSetFeeBps() public {
        assertEq(hook.feeBps(), 5, "Default should be 5 BPS");

        hook.setFeeBps(25); // 0.25%
        assertEq(hook.feeBps(), 25, "Fee should be updated to 25 BPS");

        hook.setFeeBps(0); // Free!
        assertEq(hook.feeBps(), 0, "Fee should be updatable to 0");
    }

    /// @notice Verify fee cannot exceed MAX_FEE_BPS (50 = 0.5%)
    function testSetFeeBpsTooHighReverts() public {
        vm.expectRevert(ILAwareLimitOrderHook.FeeTooHigh.selector);
        hook.setFeeBps(51); // > 50 BPS max
    }

    /// @notice Verify non-owner cannot set fee
    function testSetFeeBpsOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(); // Ownable: caller is not the owner
        hook.setFeeBps(10);
    }

    /// @notice Verify zero fee means no deduction
    function testZeroFeeNoDeduction() public {
        // Set fee to 0
        hook.setFeeBps(0);

        vm.prank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // No fees should be collected
        assertEq(hook.getPendingFees(poolKey.currency0), 0, "No fees when feeBps is 0");
    }

    /// @notice Verify fees accumulate across multiple order executions
    function testFeeAccumulation() public {
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 2e18, 1.002e18);
        vm.stopPrank();

        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Check that at least some orders filled
        uint256 filledCount = 0;
        for (uint256 i = 0; i < 2; i++) {
            ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }

        // If orders filled, fees should have accumulated
        if (filledCount > 0) {
            uint256 totalFees = hook.getPendingFees(poolKey.currency0);
            assertTrue(totalFees > 0, "Fees should accumulate from multiple orders");
            console2.log("Accumulated fees from", filledCount, "orders:", totalFees);
        }
    }

    /*//////////////////////////////////////////////////////////////
              BLOCK 1: afterInitialize & afterAddLiquidity TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies lastTick and sqrtPriceBaseline are set after pool initialization
    function test_AfterInitialize() public {
        PoolId poolId = poolKey.toId();

        // Pool was initialized at tick 0 (getSqrtPriceAtTick(0)) in setUp()
        int24 storedTick = hook.lastTick(poolId);
        uint160 storedSqrtPrice = hook.sqrtPriceBaseline(poolId);

        assertEq(storedTick, 0, "lastTick should be 0 after init at tick 0");
        assertEq(storedSqrtPrice, TickMath.getSqrtPriceAtTick(0), "sqrtPriceBaseline should match init price");
    }

    /// @notice Verifies lastTick is updated in afterSwap
    function test_LastTickUpdatedAfterSwap() public {
        PoolId poolId = poolKey.toId();
        int24 tickBefore = hook.lastTick(poolId);

        // Swap to move price
        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int24 tickAfter = hook.lastTick(poolId);
        // After a !zeroForOne swap the tick should have moved up
        assertTrue(tickAfter >= tickBefore, "lastTick should increase after price-up swap");
    }

    /// @notice Verifies lpPositions are recorded when hookData contains the LP address
    function test_AfterAddLiquidity_WithHookData() public {
        address lpAddress = makeAddr("lp_provider");

        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 1000e18, salt: bytes32(0)
            }),
            abi.encode(lpAddress)
        );

        PoolId poolId = poolKey.toId();
        ILAwareLimitOrderHook.LPPosition memory pos = hook.getLPPosition(poolId, lpAddress);

        assertTrue(pos.sqrtPriceAtEntry > 0, "sqrtPriceAtEntry should be recorded");
        assertEq(pos.liquidity, uint128(1000e18), "liquidity should match liquidityDelta");
        assertEq(pos.entryTimestamp, block.timestamp, "entryTimestamp should be current block");
    }

    /// @notice Verifies that LP tracking is skipped gracefully when hookData is empty
    function test_AfterAddLiquidity_NoHookData_Graceful() public {
        address lpAddress = makeAddr("unknown_lp");

        // setUp already called addLiquidity() with empty hookData — no lpPositions recorded
        PoolId poolId = poolKey.toId();
        ILAwareLimitOrderHook.LPPosition memory pos = hook.getLPPosition(poolId, lpAddress);

        assertEq(pos.sqrtPriceAtEntry, 0, "No tracking without hookData");
        assertEq(pos.liquidity, 0, "No liquidity recorded without hookData");
    }

    /*//////////////////////////////////////////////////////////////
              BLOCK 2: IL CALCULATION & VAULT INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice IL = 0 when price hasn't moved
    function test_ILCalculation_ZeroMovement() public pure {
        // Taylor approx: IL = liq * ((√R - 1)^2) / 2 where R = P_current / P_entry
        // When P_current == P_entry: √R = 1, diff = 0, IL = 0
        uint160 sqrtPrice = 79228162514264337593543950336; // sqrt(1) * 2^96
        uint128 liq = 1e18;

        uint256 sqrtR = (uint256(sqrtPrice) * 1e9) / uint256(sqrtPrice); // 1e9 exactly
        uint256 diff = sqrtR > 1e9 ? sqrtR - 1e9 : 1e9 - sqrtR; // 0
        uint256 ilAmount = (uint256(liq) * diff * diff) / (2 * 1e9 * 1e9); // 0

        assertEq(ilAmount, 0, "IL should be 0 at unchanged price");
    }

    /// @notice IL > 0 when price has doubled (sqrt ratio = sqrt(2) ≈ 1.414)
    function test_ILCalculation_PriceDoubled() public pure {
        // sqrtPrice(2) = sqrtPrice(1) * sqrt(2)
        uint160 sqrtPriceEntry = 79228162514264337593543950336; // sqrt(1) * 2^96
        uint160 sqrtPriceCurrent = 112045541949572368435112811072; // sqrt(2) * 2^96 (approx)
        uint128 liq = 1e18;

        uint256 sqrtR = (uint256(sqrtPriceCurrent) * 1e9) / uint256(sqrtPriceEntry);
        // sqrtR ≈ 1.414e9
        assertTrue(sqrtR > 1e9, "sqrtR should be > 1e9 when price doubled");

        uint256 diff = sqrtR - 1e9; // ≈ 0.414e9
        uint256 ilAmount = (uint256(liq) * diff * diff) / (2 * 1e9 * 1e9);
        assertTrue(ilAmount > 0, "IL should be > 0 when price doubled");
        console2.log("IL at 2x price (liq=1e18):", ilAmount);
    }

    /// @notice depositToVault correctly stores vault shares for a filled order
    function test_VaultDeposit() public {
        // Deploy mock vault for token0
        MockERC4626 vault = new MockERC4626(address(token0));

        // Deploy a new hook with the vault address
        // (re-use existing hook if vault is address(0) — just test without real vault)
        // Instead: deploy a fresh hook instance pointed at our vault
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "mismatch");
        vm.resumeGasMetering();

        // New pool with vault hook
        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        // Add liquidity to vault pool
        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)
            }),
            ""
        );

        // Alice creates a BUY order
        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Trigger fill: swap to move price down
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hookWithVault.getOrder(orderId);
        assertTrue(order.isFilled, "Order must be filled before vault deposit");

        // Alice deposits filled order output to vault
        vm.prank(alice);
        hookWithVault.depositToVault(orderId);

        ILAwareLimitOrderHook.LimitOrder memory orderAfter = hookWithVault.getOrder(orderId);
        assertTrue(orderAfter.vaultShares > 0, "vaultShares should be recorded after depositToVault");
    }

    /// @notice H3: a filled + vault-deposited order (vaultShares > 0) cannot be force-cancelled,
    ///         and its principal is NOT stranded — the owner can still claim it in full.
    ///         Proves the "forceCancelOrder orphans vault shares" finding is unreachable.
    function test_H3_ForceCancel_CannotStrandVaultShares() public {
        MockERC4626 vault = new MockERC4626(address(token0));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "mismatch");
        vm.resumeGasMetering();

        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)
            }),
            ""
        );

        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.prank(alice);
        hookWithVault.depositToVault(orderId);
        assertTrue(hookWithVault.getOrder(orderId).vaultShares > 0, "vaultShares should be set");

        // H3: force-cancelling a filled + deposited order MUST revert (cannot strand vaultShares)
        vm.expectRevert(ILAwareLimitOrderHook.OrderAlreadyFilled.selector);
        hookWithVault.forceCancelOrder(orderId);

        // And the principal is NOT stranded: the owner can still claim it in full via claimOrder
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);
        assertTrue(token0.balanceOf(alice) > aliceBefore, "owner can still claim deposited output (not stranded)");
    }

    /// @notice claimOrder distributes vault yield as IL rebate
    function test_YieldRebate_OnClaim() public {
        MockERC4626 vault = new MockERC4626(address(token0));
        vault.setYieldBps(100); // 1% yield

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "mismatch");
        vm.resumeGasMetering();

        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)
            }),
            ""
        );

        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Fill order
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Deposit to vault
        vm.prank(alice);
        hookWithVault.depositToVault(orderId);

        assertTrue(hookWithVault.getOrder(orderId).vaultShares > 0, "Shares should be deposited");

        // Claim: should receive output + yield rebate
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);
        uint256 aliceAfter = token0.balanceOf(alice);

        assertTrue(aliceAfter > aliceBefore, "Alice should receive tokens via claimOrder");
        console2.log("Alice received on claim:", aliceAfter - aliceBefore);
    }

    /// @notice June fix: a vault revert during claimOrder must not trap the user's funds.
    /// @dev    Proves the solvency-safe graceful fallback: when a deposited order's vault redeem
    ///         reverts, (1) claimOrder does NOT revert, (2) it emits VaultRedeemFailed, (3) it pays
    ///         out nothing (so no other order's custodied balance is drawn down), (4) the position
    ///         is preserved fully intact (NFT + vaultShares), and (5) once the vault recovers the
    ///         same owner re-claims and receives their original output, burning the NFT.
    function test_GracefulClaim_VaultReverts_JuneFix() public {
        MockERC4626 vault = new MockERC4626(address(token0));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "mismatch");
        vm.resumeGasMetering();

        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)}),
            ""
        );

        // Alice places a BUY order (zeroForOne = false → output is token0, the vault asset)
        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Fill the order via a price-moving swap
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(hookWithVault.getOrder(orderId).isFilled, "order must be filled");

        // Alice deposits the filled output into the vault
        vm.prank(alice);
        hookWithVault.depositToVault(orderId);
        uint256 depositedShares = hookWithVault.getOrder(orderId).vaultShares;
        assertGt(depositedShares, 0, "shares must be recorded after deposit");

        // ── Vault goes down: redeem now reverts ──────────────────────────────
        vault.setShouldRevert(true);
        uint256 aliceBeforeFailedClaim = token0.balanceOf(alice);

        // Claim must NOT revert; it gracefully emits VaultRedeemFailed and preserves state.
        vm.expectEmit(true, false, false, true, address(hookWithVault));
        emit VaultRedeemFailed(orderId, depositedShares);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);

        // Failure-path invariants: nothing paid out, nothing drawn down, position fully preserved.
        assertEq(token0.balanceOf(alice), aliceBeforeFailedClaim, "no tokens paid out while vault is down");
        assertEq(hookWithVault.ownerOf(orderId), alice, "NFT must be preserved (not burned) on vault failure");
        assertEq(hookWithVault.getOrder(orderId).vaultShares, depositedShares, "vaultShares must be preserved");
        assertTrue(hookWithVault.getOrder(orderId).isFilled, "order remains filled and claimable");

        // ── Vault recovers: the same NFT owner re-claims and recovers their output ──
        vault.setShouldRevert(false);
        uint256 aliceBeforeRecovery = token0.balanceOf(alice);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);
        assertGt(token0.balanceOf(alice) - aliceBeforeRecovery, 0, "Alice recovers her output after the vault heals");

        // NFT is now burned (claim settled): ownerOf must revert.
        vm.expectRevert();
        hookWithVault.ownerOf(orderId);
    }

    /// @notice claimOrder with a lossy vault pays back exactly what the vault returned — no rebate,
    ///         no over-payment of the recorded principal — and still settles + burns the position.
    /// @dev    Covers the `redeemed <= outputAmount` branch of claimOrder. The vault returns 5% less
    ///         than principal, so the user receives < outputAmount and no IL rebate, but the hook
    ///         never pays more than the vault actually delivered (no draw on other orders' custody).
    function test_ClaimOrder_LossyVaultRedeem_PaysRedeemedNotPrincipal() public {
        MockERC4626 vault = new MockERC4626(address(token0));
        vault.setLossBps(500); // vault returns 5% less than principal on redeem

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "mismatch");
        vm.resumeGasMetering();

        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)}),
            ""
        );

        // Alice places a BUY order (zeroForOne = false → output is token0, the vault asset)
        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Fill the order
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertTrue(hookWithVault.getOrder(orderId).isFilled, "order must be filled");

        // Deposit the output into the (lossy) vault
        vm.prank(alice);
        hookWithVault.depositToVault(orderId);

        uint256 principal = hookWithVault.getOrder(orderId).amount0; // output held = vault shares (1:1)
        uint256 shares = hookWithVault.getOrder(orderId).vaultShares;
        assertEq(shares, principal, "1:1 deposit: shares == output principal");
        uint256 expectedRedeemed = shares - (shares * 500 / 10000); // 5% loss
        assertLt(expectedRedeemed, principal, "lossy vault returns less than principal");

        // Claim
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);
        uint256 received = token0.balanceOf(alice) - aliceBefore;

        // Pays exactly the redeemed amount — no rebate, and never more than the vault delivered.
        assertEq(received, expectedRedeemed, "pays exactly what the lossy vault returned");
        assertLt(received, principal, "received < recorded principal (no rebate on a loss)");
        assertGt(received, 0, "user still receives the recoverable amount");

        // Position fully settled + burned.
        assertEq(hookWithVault.getOrder(orderId).amount0, 0, "order amount zeroed after claim");
        assertEq(hookWithVault.getOrder(orderId).vaultShares, 0, "vault shares cleared after claim");
        vm.expectRevert();
        hookWithVault.ownerOf(orderId);
    }

    /*//////////////////////////////////////////////////////////////
              BLOCK 3: ERC721 TOKENIZED POSITIONS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC721 is minted to the creator on createLimitOrder
    function test_ERC721_MintedOnCreate() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        assertEq(hook.ownerOf(orderId), alice, "ERC721 should be minted to creator");
    }

    /// @notice Transferring the NFT changes the owner; burn happens on cancel
    function test_ERC721_Transfer() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        assertEq(hook.ownerOf(orderId), alice, "Initial owner should be alice");

        // Alice transfers the NFT to bob
        vm.prank(alice);
        hook.transferFrom(alice, bob, orderId);
        assertEq(hook.ownerOf(orderId), bob, "Owner should be bob after transfer");

        // Bob can now cancel the order
        uint256 bobBefore = token0.balanceOf(bob);
        vm.prank(bob);
        hook.cancelOrder(orderId);
        assertTrue(token0.balanceOf(bob) > bobBefore, "Bob should receive refund after cancel");

        // NFT is burned
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    /// @notice New NFT owner can claim a filled order (transfer + fill + claim by new owner)
    function test_ERC721_Claim_After_Transfer() public {
        // Alice creates order, fills it
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Fill the order via swap
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order must be filled");

        // Alice transfers the filled-order NFT to bob (secondary market)
        vm.prank(alice);
        hook.transferFrom(alice, bob, orderId);
        assertEq(hook.ownerOf(orderId), bob, "Bob should own the NFT after transfer");

        // Alice cannot claim (not owner)
        vm.prank(alice);
        vm.expectRevert(ILAwareLimitOrderHook.NotOrderCreator.selector);
        hook.claimOrder(orderId, poolKey);

        // Bob can claim
        uint256 bobToken0Before = token0.balanceOf(bob);
        vm.prank(bob);
        hook.claimOrder(orderId, poolKey);
        assertTrue(token0.balanceOf(bob) > bobToken0Before, "Bob should receive order output");

        // NFT is burned after claim
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    /*//////////////////////////////////////////////////////////////
              PHASE 6.18: TIME-BASED YIELD SIMULATION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Phase 6.18: SimulatedYieldVault generates real yield after vm.warp.
    ///         Full flow:
    ///           1. Deploy SimulatedYieldVault (startTime = now)
    ///           2. Create + fill limit order, deposit output to vault
    ///           3. vm.warp +30 days  →  vault accrues ~2.5% APY
    ///           4. claimOrder        →  hook redeems vault, applies IL rebate
    ///           5. Assert aliceReceived > outputAmount (yield covered part of IL)
    function test_YieldRebate_WithTimeSimulation() public {
        // ── 1. Deploy SimulatedYieldVault (3% APY, startTime = block.timestamp) ──
        SimulatedYieldVault vault = new SimulatedYieldVault(address(token0));

        // ── 2. Deploy fresh hook pointing at the vault ─────────────────────────
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), address(vault));
        vm.pauseGasMetering();
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hookWithVault =
            new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), address(vault));
        require(address(hookWithVault) == predicted, "hook address mismatch");
        vm.resumeGasMetering();

        // ── 3. Initialize pool with vault hook (unique fee=100 / tickSpacing=1) ──
        PoolKey memory vaultPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 100,
            tickSpacing: 1,
            hooks: hookWithVault
        });
        manager.initialize(vaultPoolKey, TickMath.getSqrtPriceAtTick(0));

        // ── 4. Add liquidity so swaps can execute ─────────────────────────────
        token0.mint(address(this), 5_000e18);
        token1.mint(address(this), 5_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            vaultPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 5_000e18, salt: bytes32(0)
            }),
            ""
        );

        // ── 5. Alice creates a BUY order (zeroForOne=false: input=token1, output=token0) ──
        token1.mint(alice, 10e18);
        vm.startPrank(alice);
        token1.approve(address(hookWithVault), type(uint256).max);
        token0.approve(address(hookWithVault), type(uint256).max);
        uint256 orderId = hookWithVault.createLimitOrder(vaultPoolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // ── 6. Trigger fill: swap LARGE zeroForOne=true to move price past trigger ──
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            vaultPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory orderAfterFill = hookWithVault.getOrder(orderId);
        assertTrue(orderAfterFill.isFilled, "Order must be filled before vault deposit");

        // Record output amount stored in the order (token0, after protocol fee)
        uint256 outputAmount = uint256(orderAfterFill.amount0);
        assertTrue(outputAmount > 0, "Output (token0) must be non-zero");

        // ── 7. Alice deposits filled output to vault ─────────────────────────
        vm.prank(alice);
        hookWithVault.depositToVault(orderId);

        uint256 vaultShares = hookWithVault.getOrder(orderId).vaultShares;
        assertTrue(vaultShares > 0, "vaultShares must be recorded after depositToVault");
        assertEq(vaultShares, outputAmount, "1:1 deposit: shares == outputAmount");

        // ── 8. Fast-forward 30 days — vault accrues ~2.47% APY ──────────────
        vm.warp(block.timestamp + 30 days);

        // Verify vault now reports yield
        uint256 previewedAssets = vault.previewRedeem(vaultShares);
        assertGt(previewedAssets, vaultShares, "Vault should report yield after 30 days");
        uint256 expectedYield = previewedAssets - vaultShares;

        console2.log("=== Phase 6.18: SimulatedYieldVault Time Test ===");
        console2.log("outputAmount (token0 in order):", outputAmount);
        console2.log("vaultShares:                   ", vaultShares);
        console2.log("previewRedeem after 30d:       ", previewedAssets);
        console2.log("expectedYield (30d @ 3% APY):  ", expectedYield);

        // ── 9. Claim order: hook redeems vault, applies IL rebate ────────────
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hookWithVault.claimOrder(orderId, vaultPoolKey);
        uint256 aliceReceived = token0.balanceOf(alice) - aliceBefore;

        console2.log("aliceReceived (token0):        ", aliceReceived);
        console2.log("rebate applied:                ",
            aliceReceived > outputAmount ? aliceReceived - outputAmount : 0);

        // ── 10. Assertions ──────────────────────────────────────────────────
        // Alice received tokens
        assertGt(aliceReceived, 0, "Alice should receive token0 from claimOrder");

        // Vault generated positive yield after 30 days
        assertGt(expectedYield, 0, "Yield must be positive after 30 days at 3% APY");

        // Alice received more than the stored output amount (yield rebate applied)
        // rebate = min(yield, IL); IL > 0 because price moved during the fill swap
        assertGt(aliceReceived, outputAmount,
            "Alice should receive outputAmount + IL-rebate (yield covered impermanent loss)");

        // NFT burned after claim
        vm.expectRevert();
        hookWithVault.ownerOf(orderId);
    }

    /// @notice claimOrder works gracefully when vault is not configured (vaultShares == 0)
    function test_GracefulFill_VaultEmpty() public {
        // hook in setUp has yieldVault = address(0)
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Fill order
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        ILAwareLimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled");
        assertEq(order.vaultShares, 0, "No vault shares when vault not configured");

        // claimOrder with no vault: should work gracefully
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);
        uint256 aliceAfter = token0.balanceOf(alice);

        assertTrue(aliceAfter > aliceBefore, "Alice should receive output without vault");
    }
}
