// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal yielding ERC-4626-ish vault (1:1 shares, simple-interest APY, mints its own yield
///      deficit). Mirrors the production SimulatedYieldVault; the hook only calls deposit + redeem.
contract YieldVault {
    IERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    uint256 public constant APY_BPS = 300;
    uint256 public immutable startTime;

    // Adversarial modes (Phase 2 coverage): make redeem revert, or return LESS than principal, so the
    // hook's graceful vault-revert catch and its lossy-redeem branch are exercised under invariants.
    bool public failRedeem;
    uint256 public haircutBps; // >0 => redeem returns principal minus this haircut (lossy)

    function setFailRedeem(bool v) external {
        failRedeem = v;
    }

    function setHaircutBps(uint256 v) external {
        haircutBps = v;
    }

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
        // Revert BEFORE any state change so a caught failure leaves shares intact for a later re-claim.
        if (failRedeem) revert("vault: redeem failed");
        require(sharesOf[owner] >= shares, "insufficient shares");
        sharesOf[owner] -= shares;
        totalShares -= shares;

        if (haircutBps > 0) {
            // Lossy: pay strictly less than principal (the vault already custodies `shares`, so no mint).
            assets = shares - (shares * haircutBps) / 10000;
        } else {
            assets = previewRedeem(shares); // principal + yield
            uint256 bal = asset.balanceOf(address(this));
            if (assets > bal) {
                (bool ok,) =
                    address(asset).call(abi.encodeWithSignature("mint(address,uint256)", address(this), assets - bal));
                if (!ok) assets = bal;
            }
        }
        asset.transfer(receiver, assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        return shares + (shares * APY_BPS * elapsed) / (10_000 * 365 days);
    }
}

/// @title Invariant handler for ILAwareLimitOrderHook (Phase 2).
/// @notice Drives random sequences against ONE hook attached to TWO pools that share currency0 (t0).
///         Vault-enabled runs also exercise depositToVault + time warps.
contract Handler is Test {
    using PoolIdLibrary for PoolKey;

    ILAwareLimitOrderHook public hook;
    PoolManager public manager;
    PoolSwapTest public swapRouter;
    address public owner; // hook owner (the invariant test contract)

    MockERC20 public t0;
    MockERC20 public t1;
    MockERC20 public t2;
    PoolKey public poolA; // (t0, t1)
    PoolKey public poolB; // (t0, t2)

    address[] public actors;
    uint256[] public orderIds; // every order id ever created (unique; each create pushes once)

    struct Bucket {
        PoolId poolId;
        int24 tick;
    }

    Bucket[] public buckets; // distinct (poolId, tick) buckets that have received an order
    mapping(bytes32 => bool) internal bucketSeen;

    // Ghost counters: coverage visibility (fail_on_revert=false, so confirm ops actually landed)
    uint256 public ghost_created;
    uint256 public ghost_swaps;
    uint256 public ghost_cancelled;
    uint256 public ghost_forceCancelled;
    uint256 public ghost_claimed;
    uint256 public ghost_deposited;
    uint256 public ghost_feeWithdrawals;

    // When true (vault suite), claim leaves undeposited t0-output orders for depositToVault, so the
    // full deposit -> yield -> redeem lifecycle is exercised instead of claim immediately grabbing
    // every fill. Models a user parking idle output in the vault before claiming.
    bool public reserveForDeposit;
    YieldVault public vault; // set only in the vault suite; enables setVaultMode

    function setReserveForDeposit(bool v) external {
        reserveForDeposit = v;
    }

    function setVault(YieldVault v) external {
        vault = v;
    }

    constructor(
        ILAwareLimitOrderHook _hook,
        PoolManager _manager,
        PoolSwapTest _swapRouter,
        address _owner,
        MockERC20 _t0,
        MockERC20 _t1,
        MockERC20 _t2,
        PoolKey memory _poolA,
        PoolKey memory _poolB
    ) {
        hook = _hook;
        manager = _manager;
        swapRouter = _swapRouter;
        owner = _owner;
        t0 = _t0;
        t1 = _t1;
        t2 = _t2;
        poolA = _poolA;
        poolB = _poolB;
        actors.push(makeAddr("inv_alice"));
        actors.push(makeAddr("inv_bob"));
        actors.push(makeAddr("inv_carol"));
    }

    /*//////////////////////////////////////////////////////////////
                        VIEWS FOR THE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function orderIdsLength() external view returns (uint256) {
        return orderIds.length;
    }

    function bucketsLength() external view returns (uint256) {
        return buckets.length;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _poolBySeed(uint256 s) internal view returns (PoolKey memory) {
        return s % 2 == 0 ? poolA : poolB;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    // Mirror of the contract's _alignTick (round toward negative infinity).
    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    // Record the (poolId, tick) bucket an order lands in, recomputed exactly like createLimitOrder.
    function _recordBucket(PoolKey memory pk, uint128 trigger) internal {
        int24 tick = _alignTick(TickMath.getTickAtSqrtPrice(hook.uint128ToSqrtPrice(trigger)), pk.tickSpacing);
        bytes32 key = keccak256(abi.encode(PoolId.unwrap(pk.toId()), tick));
        if (!bucketSeen[key]) {
            bucketSeen[key] = true;
            buckets.push(Bucket(pk.toId(), tick));
        }
    }

    function _ownerOrZero(uint256 id) internal view returns (address) {
        try hook.ownerOf(id) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function createOrder(uint256 actorSeed, uint256 poolSeed, bool zeroForOne, uint96 amount, uint128 trigger)
        external
    {
        // ~1 in 5 orders is large relative to the ~0.5% tolerance-band depth, so the M4 hard gate
        // binds and the order PARTIALLY fills (refunding the unused input) — exercising the refund
        // accounting against solvency. The rest are ordinary full-fill sizes.
        bool large = (uint256(amount) % 5 == 0);
        amount = large
            ? uint96(bound(uint256(amount), 300e18, 5000e18))
            : uint96(bound(uint256(amount), 1e15, 100e18));
        PoolKey memory pk = _poolBySeed(poolSeed);

        // Price-aware trigger: ~half the orders are made immediately eligible relative to the pool's
        // CURRENT price (so they fill on the next correct-direction swap — keeps fill/claim/deposit
        // well exercised), the other half sit as resting orders for the custody / bucket-hygiene
        // invariants. SELL (zeroForOne) is eligible when price >= trigger; BUY when price <= trigger.
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), pk.toId());
        uint128 curP = hook.sqrtPriceToUint128(sp);
        if (actorSeed % 3 != 0) {
            // Two-thirds: immediately eligible. Force a BUY (t0-output) — the direction that feeds
            // the deposit/vault path (SELL fills are still produced by the resting/random third).
            zeroForOne = false;
            trigger = uint128(bound(uint256(trigger), curP, (uint256(curP) * 110) / 100)); // BUY: price <= trigger
        } else {
            // One-third: resting-ish order in the fuzzer's own direction, for custody / bucket / SELL
            // coverage (may or may not become eligible as the price wanders).
            trigger = uint128(bound(uint256(trigger), (uint256(curP) * 80) / 100, (uint256(curP) * 120) / 100));
        }
        if (trigger == 0) trigger = 1;
        address actor = _actor(actorSeed);
        MockERC20 inTok = MockERC20(Currency.unwrap(zeroForOne ? pk.currency0 : pk.currency1));

        inTok.mint(actor, amount);
        vm.startPrank(actor);
        inTok.approve(address(hook), amount);
        uint256 id = hook.createLimitOrder(pk, zeroForOne, amount, trigger);
        vm.stopPrank();

        orderIds.push(id);
        _recordBucket(pk, trigger);
        ghost_created++;
    }

    function doSwap(uint256 poolSeed, bool zeroForOne, uint96 amount) external {
        amount = uint96(bound(uint256(amount), 1e15, 2000e18));
        PoolKey memory pk = _poolBySeed(poolSeed);
        MockERC20 inTok = MockERC20(Currency.unwrap(zeroForOne ? pk.currency0 : pk.currency1));

        inTok.mint(address(this), amount);
        inTok.approve(address(swapRouter), amount);
        swapRouter.swap(
            pk,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amount)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        ghost_swaps++;
    }

    function cancel(uint256 orderSeed) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[orderSeed % orderIds.length];
        address o = _ownerOrZero(id);
        if (o == address(0)) return;
        if (hook.getOrder(id).isFilled) return;
        vm.prank(o);
        try hook.cancelOrder(id) {
            ghost_cancelled++;
        } catch {}
    }

    function forceCancel(uint256 orderSeed) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[orderSeed % orderIds.length];
        if (_ownerOrZero(id) == address(0)) return;
        if (hook.getOrder(id).isFilled) return;
        vm.prank(owner);
        try hook.forceCancelOrder(id) {
            ghost_forceCancelled++;
        } catch {}
    }

    // Scan from a random offset for the first filled order and claim it (a plain random pick almost
    // never lands on a filled order, leaving the claim path under-exercised).
    function claim(uint256 seed) external {
        uint256 n = orderIds.length;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = orderIds[(seed + k) % n];
            address o = _ownerOrZero(id);
            if (o == address(0)) continue;
            ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(id);
            if (!ord.isFilled) continue;
            // In the vault suite, reserve undeposited t0-output fills for depositToVault.
            if (reserveForDeposit && ord.vaultShares == 0 && (ord.zeroForOne ? ord.token1 : ord.token0) == address(t0)) {
                continue;
            }
            PoolKey memory pk = PoolId.unwrap(ord.poolId) == PoolId.unwrap(poolA.toId()) ? poolA : poolB;
            vm.prank(o);
            try hook.claimOrder(id, pk) {
                ghost_claimed++;
            } catch {}
            return;
        }
    }

    // Scan for the first filled, not-yet-deposited order whose output is the vault asset (t0) and
    // deposit it — otherwise the vault-share invariant is vacuous (deposits almost never land).
    function depositToVault(uint256 seed) external {
        uint256 n = orderIds.length;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = orderIds[(seed + k) % n];
            address o = _ownerOrZero(id);
            if (o == address(0)) continue;
            ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(id);
            if (!ord.isFilled || ord.vaultShares > 0) continue;
            address outTok = ord.zeroForOne ? ord.token1 : ord.token0;
            if (outTok != address(t0)) continue; // only t0-output orders can actually deposit
            vm.prank(o);
            try hook.depositToVault(id) {
                ghost_deposited++;
            } catch {}
            // no return: sweep every eligible filled order into the vault in this call
        }
    }

    function withdrawFees(uint256 curSeed) external {
        MockERC20 tok = curSeed % 3 == 0 ? t0 : (curSeed % 3 == 1 ? t1 : t2);
        vm.prank(owner);
        try hook.withdrawFees(Currency.wrap(address(tok)), owner) {
            ghost_feeWithdrawals++;
        } catch {}
    }

    function setFee(uint256 bps) external {
        bps = bound(bps, 0, hook.MAX_FEE_BPS());
        vm.prank(owner);
        try hook.setFeeBps(bps) {} catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    // Toggle the vault between normal-yield, lossy, and reverting-redeem so claimOrder's graceful
    // catch and lossy-redeem branch are exercised. The solvency + share invariants must hold in all.
    function setVaultMode(uint256 seed) external {
        if (address(vault) == address(0)) return;
        vault.setFailRedeem(seed % 4 == 0); // ~25%: redeem reverts -> claimOrder catch path
        vault.setHaircutBps(seed % 3 == 0 ? bound(seed, 1, 300) : 0); // sometimes lossy (<= 3%)
    }
}

/// @title Shared setup + invariants for the ILAwareLimitOrderHook invariant suites (Phase 2).
abstract contract InvariantBase is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    ILAwareLimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    MockERC20 t0;
    MockERC20 t1;
    MockERC20 t2;
    PoolKey poolA; // (t0, t1)
    PoolKey poolB; // (t0, t2)

    Handler handler;
    YieldVault internal vault; // null in the no-vault suite

    /// @dev Deploy the manager, 3 tokens (t0 = global-min so both pools use it as currency0), an
    ///      optional yielding vault on t0, the hook, two pools sharing t0, liquidity, and the handler
    ///      restricted to `selectors`.
    function _deployCore(bool withVault, bytes4[] memory selectors) internal {
        manager = new PoolManager(address(this));
        (t0, t1, t2) = _sort3(new MockERC20("T0", "T0", 18), new MockERC20("T1", "T1", 18), new MockERC20("T2", "T2", 18));

        address vaultAddr = address(0);
        if (withVault) {
            vault = new YieldVault(address(t0));
            vaultAddr = address(vault);
        }

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), vaultAddr);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        hook = new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), vaultAddr);
        require(address(hook) == predicted, "hook addr mismatch");

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        poolA = PoolKey({currency0: Currency.wrap(address(t0)), currency1: Currency.wrap(address(t1)), fee: 3000, tickSpacing: 60, hooks: hook});
        poolB = PoolKey({currency0: Currency.wrap(address(t0)), currency1: Currency.wrap(address(t2)), fee: 3000, tickSpacing: 60, hooks: hook});
        manager.initialize(poolA, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolB, TickMath.getSqrtPriceAtTick(0));

        _addLiquidity(poolA);
        _addLiquidity(poolB);

        handler = new Handler(hook, manager, swapRouter, address(this), t0, t1, t2, poolA, poolB);

        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                          SHARED INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook must always hold at least what it owes, per currency: unfilled-order custody
    ///         + filled-unclaimed-order output + pendingFees (now including un-rebated vault yield,
    ///         which is captured to pendingFees on claim rather than stranded). `>=` (not `==`) because
    ///         ERC-4626 share-redemption rounding can leave sub-wei dust as a safe surplus.
    function invariant_solvency() public view {
        (uint256 o0, uint256 o1, uint256 o2) = _obligations();
        assertGe(t0.balanceOf(address(hook)), o0, "t0 insolvent");
        assertGe(t1.balanceOf(address(hook)), o1, "t1 insolvent");
        assertGe(t2.balanceOf(address(hook)), o2, "t2 insolvent");
    }

    /// @notice Every order in a (poolId, tick) bucket must belong to that pool (H1/H2), be live (not
    ///         burned) and unfilled (fills/cancels remove immediately), and appear at most once in
    ///         the bucket (M3 swap-and-pop consistency).
    function invariant_poolIsolationAndBucketHygiene() public view {
        uint256 nb = handler.bucketsLength();
        for (uint256 b = 0; b < nb; b++) {
            (PoolId pid, int24 tick) = handler.buckets(b);
            uint256[] memory ids = hook.getOrdersInTick(pid, tick);
            for (uint256 j = 0; j < ids.length; j++) {
                uint256 id = ids[j];
                ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(id);

                assertEq(PoolId.unwrap(ord.poolId), PoolId.unwrap(pid), "bucket holds a foreign-pool order");
                assertFalse(ord.isFilled, "filled order lingering in bucket");

                bool burned;
                try hook.ownerOf(id) returns (address) {
                    burned = false;
                } catch {
                    burned = true;
                }
                assertFalse(burned, "burned order lingering in bucket");

                for (uint256 k = j + 1; k < ids.length; k++) {
                    assertTrue(ids[k] != id, "duplicate order id within a bucket");
                }
            }
        }
    }

    function invariant_callSummary() public view {
        console2.log("created   ", handler.ghost_created());
        console2.log("swaps     ", handler.ghost_swaps());
        console2.log("cancelled ", handler.ghost_cancelled());
        console2.log("forceCncl ", handler.ghost_forceCancelled());
        console2.log("claimed   ", handler.ghost_claimed());
        console2.log("deposited ", handler.ghost_deposited());
        console2.log("feeWdraws ", handler.ghost_feeWithdrawals());

        uint256 filled;
        uint256 filledT0;
        uint256 n = handler.orderIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.orderIds(i);
            try hook.ownerOf(id) returns (address) {} catch {
                continue;
            }
            ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(id);
            if (ord.isFilled) {
                filled++;
                if ((ord.zeroForOne ? ord.token1 : ord.token0) == address(t0)) filledT0++;
            }
        }
        console2.log("filledNow ", filled);
        console2.log("filledT0Now", filledT0);
    }

    /*//////////////////////////////////////////////////////////////
                              OBLIGATIONS
    //////////////////////////////////////////////////////////////*/

    function _obligations() internal view returns (uint256 o0, uint256 o1, uint256 o2) {
        uint256 n = handler.orderIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.orderIds(i);

            // Burned (cancelled / force-cancelled / claimed): no hook-balance obligation.
            try hook.ownerOf(id) returns (address) {} catch {
                continue;
            }

            ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(id);
            address cur;
            uint256 amt;
            if (!ord.isFilled) {
                // Custody of the input token.
                cur = ord.zeroForOne ? ord.token0 : ord.token1;
                amt = ord.zeroForOne ? uint256(ord.amount0) : uint256(ord.amount1);
            } else {
                // Filled: output held in the hook until claimed. vaultShares>0 => the output was
                // moved into the vault (not the hook balance) — excluded here; the vault backs it.
                if (ord.vaultShares > 0) continue;
                cur = ord.zeroForOne ? ord.token1 : ord.token0;
                amt = ord.zeroForOne ? uint256(ord.amount1) : uint256(ord.amount0);
            }

            if (cur == address(t0)) o0 += amt;
            else if (cur == address(t1)) o1 += amt;
            else if (cur == address(t2)) o2 += amt;
        }

        o0 += hook.pendingFees(Currency.wrap(address(t0)));
        o1 += hook.pendingFees(Currency.wrap(address(t1)));
        o2 += hook.pendingFees(Currency.wrap(address(t2)));
    }

    /*//////////////////////////////////////////////////////////////
                              SETUP HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sort3(MockERC20 a, MockERC20 b, MockERC20 c)
        internal
        pure
        returns (MockERC20 mn, MockERC20 x, MockERC20 y)
    {
        mn = a;
        if (address(b) < address(mn)) mn = b;
        if (address(c) < address(mn)) mn = c;
        if (mn == a) {
            (x, y) = (b, c);
        } else if (mn == b) {
            (x, y) = (a, c);
        } else {
            (x, y) = (a, b);
        }
    }

    function _addLiquidity(PoolKey memory pk) internal {
        MockERC20 c0 = MockERC20(Currency.unwrap(pk.currency0));
        MockERC20 c1 = MockERC20(Currency.unwrap(pk.currency1));
        c0.mint(address(this), 2_000_000e18);
        c1.mint(address(this), 2_000_000e18);
        c0.approve(address(lpRouter), type(uint256).max);
        c1.approve(address(lpRouter), type(uint256).max);
        // Wide range + deep liquidity: swaps can move price across the whole [0.9, 1.1] trigger band
        // (so orders actually fill) without exhausting the range and reverting.
        lpRouter.modifyLiquidity(
            pk,
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 50_000e18, salt: bytes32(0)}),
            ""
        );
    }
}

/// @notice No-vault configuration: every filled order's output is held directly by the hook.
contract ILAwareLimitOrderHookInvariant is InvariantBase {
    function setUp() public {
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = Handler.createOrder.selector;
        sel[1] = Handler.doSwap.selector;
        sel[2] = Handler.cancel.selector;
        sel[3] = Handler.forceCancel.selector;
        sel[4] = Handler.claim.selector;
        sel[5] = Handler.withdrawFees.selector;
        sel[6] = Handler.setFee.selector;
        _deployCore(false, sel);
    }
}

/// @notice Vault configuration: a yielding vault on t0. Orders whose output is t0 (!zeroForOne, in
///         either pool) can be deposited; the vault path, yield surplus, and share accounting are
///         exercised alongside solvency.
contract ILAwareLimitOrderHookVaultInvariant is InvariantBase {
    function setUp() public {
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = Handler.createOrder.selector;
        sel[1] = Handler.doSwap.selector;
        sel[2] = Handler.cancel.selector;
        sel[3] = Handler.forceCancel.selector;
        sel[4] = Handler.claim.selector;
        sel[5] = Handler.depositToVault.selector;
        sel[6] = Handler.withdrawFees.selector;
        sel[7] = Handler.setFee.selector;
        sel[8] = Handler.warp.selector;
        sel[9] = Handler.setVaultMode.selector;
        _deployCore(true, sel);
        handler.setReserveForDeposit(true);
        handler.setVault(vault);
    }

    /// @notice Every share the vault holds for the hook is backed by exactly one live order's
    ///         recorded vaultShares — no drift, no orphaned or double-counted shares (M2 vault path).
    function invariant_vaultSharesConsistent() public view {
        uint256 sum;
        uint256 n = handler.orderIdsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += hook.getOrder(handler.orderIds(i)).vaultShares;
        }
        assertEq(sum, vault.sharesOf(address(hook)), "vault share accounting drift");
    }
}
