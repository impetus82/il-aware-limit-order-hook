// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// @dev ERC20 that reverts on ONE specific transfer — (from = hook, to = poolManager), i.e. the
///      hook's fill-body input settle — without disturbing order creation (transferFrom), liquidity,
///      or the user swap's own settlement. Used to force a revert INSIDE _fillOrder.
contract TrapToken is MockERC20 {
    address public trapFrom;
    address public trapTo;
    bool public armed;

    constructor() MockERC20("Trap", "TRAP", 18) {}

    function arm(address _from, address _to) external {
        trapFrom = _from;
        trapTo = _to;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && msg.sender == trapFrom && to == trapTo) revert("trapped-settle");
        return super.transfer(to, amount);
    }
}

interface IHookReentry {
    function cancelOrder(uint256 orderId) external;
}

/// @dev ERC20 that OWNS a limit order and, on the hook's fill-body settle transfer (hook ->
///      poolManager), re-enters cancelOrder(orderId) as that owner — the LOW #3 execution-path
///      reentrancy vector. Post-fix the reentrant call reverts (ExecutionInProgress), which bubbles
///      into the fill body and is caught (OrderExecutionFailed), so no double-spend occurs.
contract ReenterCancelToken is MockERC20 {
    address public hook;
    uint256 public orderId;
    address public trapTo;
    bool public armed;

    constructor() MockERC20("Reenter", "RE", 18) {}

    function arm(address _hook, uint256 _orderId, address _trapTo) external {
        hook = _hook;
        orderId = _orderId;
        trapTo = _trapTo;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && msg.sender == hook && to == trapTo) {
            IHookReentry(hook).cancelOrder(orderId); // reenter mid-fill, as the order's owner
        }
        return super.transfer(to, amount);
    }
}

/// @dev Fee-on-transfer ERC20: every transfer/transferFrom delivers `amount` minus `feeBps`, the fee
///      burned. Used to prove the hook records the MEASURED receipt, not the requested amountIn (LOW #4).
contract FeeOnTransferToken is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 _feeBps) MockERC20("FoT", "FOT", 18) {
        feeBps = _feeBps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        burn(to, (amount * feeBps) / 10_000);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        burn(to, (amount * feeBps) / 10_000);
        return true;
    }
}

/// @title Regression tests for the two P0 audit findings (2026-08-08 internal audit)
/// @notice
///   MEDIUM #1 — active-tick scan burns MAX_ACTIVE_TICK_SCAN on INELIGIBLE ticks, so an
///              eligible order below >100 ineligible ticks never fills.
///   MEDIUM #2 — a revert inside the fill body (toUint96 overflow / reverting token) is
///              uncaught, so it bubbles out of afterSwap and DoSes the user's whole swap.
contract AuditP0RegressionTest is Test {
    PoolManager manager;
    ILAwareLimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;

    address alice = makeAddr("alice");

    event OrderExecutionFailed(uint256 indexed orderId, string reason);

    function setUp() public {
        manager = new PoolManager(address(this));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

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

        // Deep liquidity so the trigger swap fills cleanly.
        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 10_000e18, salt: bytes32(0)}),
            ""
        );

        token0.mint(alice, 1_000_000e18);
        token1.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _swapPriceUp(uint256 amount1In) internal {
        token1.mint(address(this), amount1In);
        token1.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount1In),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice MEDIUM #1 — a SELL order eligible after a price-up swap must still fill even when
    ///         >100 ineligible high-trigger ticks sit above it. Currently the downward scan starts
    ///         at the top and burns all 100 scan slots on the ineligible decoys, so the victim never
    ///         fills. After the fix (budget counts only ticks with an eligible order) it fills.
    function test_M1_eligibleOrderFillsDespiteManyIneligibleHighTicks() public {
        // Victim: SELL token0, trigger just above spot (tick ~0). Eligible after a small up-move.
        vm.prank(alice);
        uint256 victimId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // 120 decoy SELL orders at distinct, far-higher triggers (all stay ineligible for any
        // realistic up-move). Base 1.5e18, stepped by 0.8%/order -> distinct 60-aligned tick buckets,
        // all well under the uint128ToSqrtPrice panic point (~1.85e19).
        uint128 trig = 1.5e18;
        for (uint256 i = 0; i < 120; i++) {
            vm.prank(alice);
            hook.createLimitOrder(poolKey, true, 1e18, trig);
            trig = uint128((uint256(trig) * 1008) / 1000);
        }

        // Push price up modestly — enough to cross the victim's trigger, nowhere near the decoys.
        _swapPriceUp(50e18);

        assertTrue(
            hook.getOrder(victimId).isFilled,
            "victim SELL order must fill once price crosses its trigger, regardless of ineligible decoys above"
        );
    }

    /// @notice MEDIUM #2 — a revert inside the fill body (here: the input-settle transfer, standing in
    ///         for the toUint96 output-overflow, which is the same code path) must NOT propagate out of
    ///         afterSwap and revert the user's swap. Before the fix the revert bubbles up and bricks
    ///         every swap crossing the tick; after the fix it is caught, the order is skipped
    ///         (OrderExecutionFailed / "FillReverted"), and the user's swap completes.
    function test_M2_fillBodyRevertDoesNotDoSTheUserSwap() public {
        // Two trap tokens so whichever sorts to currency0 is one we can arm — the SELL order then
        // sells currency0 and the hook must settle it (the trapped transfer) during the fill.
        TrapToken tA = new TrapToken();
        TrapToken tB = new TrapToken();
        (TrapToken c0, TrapToken c1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(c0)),
            currency1: Currency.wrap(address(c1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(pk, TickMath.getSqrtPriceAtTick(0));

        c0.mint(address(this), 10_000e18);
        c1.mint(address(this), 10_000e18);
        c0.approve(address(modifyLiquidityRouter), type(uint256).max);
        c1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            pk,
            IPoolManager.ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 10_000e18, salt: bytes32(0)}),
            ""
        );

        // Alice: SELL currency0 (the trap token), trigger just above spot.
        c0.mint(alice, 10e18);
        vm.startPrank(alice);
        c0.approve(address(hook), type(uint256).max);
        uint256 orderId = hook.createLimitOrder(pk, true, 1e18, 1.002e18);
        vm.stopPrank();

        // Arm the trap so ONLY the hook -> poolManager settle transfer reverts.
        c0.arm(address(hook), address(manager));

        // A normal user swap pushes price up across the trigger; the hook attempts the fill, hits the
        // trapped settle, and reverts inside _fillOrder. The wrapper must catch it.
        c1.mint(address(this), 50e18);
        c1.approve(address(swapRouter), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(hook));
        emit OrderExecutionFailed(orderId, "FillReverted");

        swapRouter.swap(
            pk,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Swap survived; the un-fillable order was skipped and stays resting (recoverable via cancel).
        assertFalse(hook.getOrder(orderId).isFilled, "trapped order must be skipped, not filled");
        assertEq(hook.ownerOf(orderId), alice, "skipped order stays resting and owned by alice");
    }

    /// @notice LOW #3 — a token that re-enters cancelOrder from inside the fill's settle transfer must
    ///         NOT be able to refund-and-burn the order mid-fill (double-spend). The isExecuting gate
    ///         makes cancel/claim/deposit/create revert while a fill is in progress; that revert is
    ///         caught, the order stays resting with its principal intact, and a normal cancel still works.
    function test_M3_reentrantCancelDuringFillIsBlocked() public {
        ReenterCancelToken tA = new ReenterCancelToken();
        ReenterCancelToken tB = new ReenterCancelToken();
        (ReenterCancelToken c0, ReenterCancelToken c1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(c0)),
            currency1: Currency.wrap(address(c1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(pk, TickMath.getSqrtPriceAtTick(0));

        c0.mint(address(this), 10_000e18);
        c1.mint(address(this), 10_000e18);
        c0.approve(address(modifyLiquidityRouter), type(uint256).max);
        c1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            pk,
            IPoolManager.ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 10_000e18, salt: bytes32(0)}),
            ""
        );

        // A SECOND, independent victim order (alice) selling the SAME token funds extra c0 custody in
        // the hook — the audit's precondition. Without it, a reentrant refund empties the hook and the
        // continuing settle self-reverts harmlessly; WITH it, a pre-fix reentrant cancel corrupts the
        // in-flight bucket iteration and DoSes the whole user swap. High trigger => stays resting.
        c0.mint(alice, 1e18);
        vm.startPrank(alice);
        c0.approve(address(hook), type(uint256).max);
        uint256 victimId = hook.createLimitOrder(pk, true, 1e18, 5e18);
        vm.stopPrank();

        // The reenter token itself owns a SELL order (sells c0), so its reentrant cancelOrder passes
        // the ownerOf check.
        c0.mint(address(c0), 1e18);
        vm.prank(address(c0));
        c0.approve(address(hook), type(uint256).max);
        vm.prank(address(c0));
        uint256 orderId = hook.createLimitOrder(pk, true, 1e18, 1.002e18);
        assertEq(hook.ownerOf(orderId), address(c0), "token owns the order");

        // Arm: on the hook -> poolManager settle transfer, re-enter cancelOrder as the owner.
        c0.arm(address(hook), orderId, address(manager));

        uint256 hookC0Before = c0.balanceOf(address(hook)); // == 2e18: both order principals

        c1.mint(address(this), 50e18);
        c1.approve(address(swapRouter), type(uint256).max);

        // The reentrant cancel reverts (gated), which bubbles into the fill and is caught.
        vm.expectEmit(true, false, false, true, address(hook));
        emit OrderExecutionFailed(orderId, "FillReverted");

        swapRouter.swap(
            pk,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // No double-spend and no DoS: swap completed, both orders untouched, all principal custodied.
        assertEq(hook.ownerOf(orderId), address(c0), "attacker order must NOT be cancelled/burned by the reentrant call");
        assertFalse(hook.getOrder(orderId).isFilled, "attacker order must not be marked filled (fill reverted cleanly)");
        assertEq(hook.ownerOf(victimId), alice, "victim order must be untouched");
        assertEq(c0.balanceOf(address(hook)), hookC0Before, "no double-spend: both principals still fully custodied");

        // The owner can still cancel normally (outside execution) and recover its principal.
        vm.prank(address(c0));
        hook.cancelOrder(orderId);
        assertEq(c0.balanceOf(address(c0)), 1e18, "owner recovers principal via a normal cancel");
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    /// @notice LOW #4 — createLimitOrder must book the MEASURED receipt, not the requested amountIn.
    ///         With a fee-on-transfer token, recording amountIn over-states custody so the last
    ///         claimant's cancel reverts (insolvency). Measuring keeps pooled custody solvent.
    function test_M4_measuredReceiptOnDeposit() public {
        FeeOnTransferToken fA = new FeeOnTransferToken(100); // 1% fee
        FeeOnTransferToken fB = new FeeOnTransferToken(100);
        (FeeOnTransferToken c0, FeeOnTransferToken c1) = address(fA) < address(fB) ? (fA, fB) : (fB, fA);

        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(c0)),
            currency1: Currency.wrap(address(c1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(pk, TickMath.getSqrtPriceAtTick(0));

        address bob = makeAddr("bob");
        c0.mint(alice, 1e18);
        c0.mint(bob, 1e18);
        vm.prank(alice);
        c0.approve(address(hook), type(uint256).max);
        vm.prank(bob);
        c0.approve(address(hook), type(uint256).max);

        // Two independent SELL orders in the same FoT token (high trigger => just rest in custody).
        vm.prank(alice);
        uint256 aId = hook.createLimitOrder(pk, true, 1e18, 5e18);
        vm.prank(bob);
        uint256 bId = hook.createLimitOrder(pk, true, 1e18, 5e18);

        // Recorded custody == what the hook actually received (0.99e18), not the requested 1e18.
        assertEq(hook.getOrder(aId).amount0, 99e16, "recorded amount must be the measured receipt");
        assertEq(hook.getOrder(bId).amount0, 99e16, "recorded amount must be the measured receipt");
        assertEq(c0.balanceOf(address(hook)), 2 * 99e16, "hook custody == sum of recorded amounts (solvent)");

        // Both users can cancel: the SECOND cancel must NOT revert (pre-fix it would, since the hook
        // recorded 2e18 but only held 1.98e18).
        vm.prank(alice);
        hook.cancelOrder(aId);
        vm.prank(bob);
        hook.cancelOrder(bId);
        assertEq(c0.balanceOf(address(hook)), 0, "all custody released, hook solvent throughout");
    }
}
