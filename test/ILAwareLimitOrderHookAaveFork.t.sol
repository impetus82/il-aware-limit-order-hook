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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice M2 — fork Base mainnet and validate the hook's ERC-4626 vault path against the REAL Aave
///         USDC "Static aToken" (waBasUSDC / StataTokenV2). NO hook logic change: the hook is already
///         written against `IERC4626`, so a real Aave wrapper plugs in via the immutable `yieldVault`.
///         Flow: create a USDC-output limit order -> fill it -> depositToVault (into real Aave) ->
///         warp forward (Aave accrues real interest) -> claimOrder (redeem + yield rebate).
///
/// Run: forge test --match-contract ILAwareLimitOrderHookAaveForkTest (needs the `base` rpc endpoint).
contract ILAwareLimitOrderHookAaveForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // ── Real Base mainnet addresses ─────────────────────────────
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6-decimals
    address constant WA_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6; // waBasUSDC, StataTokenV2 (ERC-4626)

    PoolManager manager;
    ILAwareLimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 other; // 6-dec counter token paired with real USDC (keeps the fill price clean)

    PoolKey poolKey;
    bool usdcIsCurrency0;

    address alice = makeAddr("alice");

    function setUp() public {
        // Network-dependent fork test — opt-in only, so the default (offline) suite is unaffected.
        // Run with:  RUN_FORK_TESTS=1 forge test --match-contract ILAwareLimitOrderHookAaveForkTest
        if (vm.envOr("RUN_FORK_TESTS", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("base"); // latest Base block via foundry.toml [rpc_endpoints] base

        // Sanity: the real Aave wrapper is the ERC-4626 we expect.
        assertEq(IERC4626(WA_USDC).asset(), USDC, "waBasUSDC asset must be USDC");

        manager = new PoolManager(address(this));
        other = new MockERC20("Counter", "OTH", 6);

        // Deploy the hook pointing yieldVault at the REAL Aave USDC Static aToken.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(this), WA_USDC);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ILAwareLimitOrderHook).creationCode, args);
        hook = new ILAwareLimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this), WA_USDC);
        require(address(hook) == predicted, "hook addr mismatch");

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        usdcIsCurrency0 = uint160(USDC) < uint160(address(other));
        (Currency c0, Currency c1) = usdcIsCurrency0
            ? (Currency.wrap(USDC), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(USDC));
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: hook});
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        // Fund this contract with both tokens (real USDC via deal), add liquidity, keep spare for swaps.
        deal(USDC, address(this), 10_000_000e6);
        other.mint(address(this), 10_000_000e6);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        other.approve(address(lpRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 1_000_000e6, salt: bytes32(0)}),
            ""
        );
    }

    /// @notice End-to-end against real Aave: a filled USDC-output order deposits into waBasUSDC, accrues
    ///         real interest over time, and is claimed with output + a self-funded yield rebate.
    function test_M2_RealAave_DepositWarpClaim() public {
        // The order must OUTPUT USDC: sell the non-USDC token. output = zeroForOne ? token1 : token0,
        // so to output USDC we sell whichever currency is NOT USDC.
        bool sellZeroForOne = !usdcIsCurrency0; // USDC=c1 -> sell c0 (z4o=true); USDC=c0 -> sell c1 (z4o=false)
        uint128 trigger = sellZeroForOne ? uint128(1.002e18) : uint128(0.998e18);
        uint96 amountIn = 1_000e6; // ~1,000 units in -> ~1,000 USDC out at ~1.0 price

        other.mint(alice, amountIn);
        vm.startPrank(alice);
        other.approve(address(hook), type(uint256).max);
        uint256 orderId = hook.createLimitOrder(poolKey, sellZeroForOne, amountIn, trigger);
        vm.stopPrank();

        // Fill: swap in the OPPOSITE direction, large enough to cross the trigger.
        _fillSwap(!sellZeroForOne, 10_000e6);

        ILAwareLimitOrderHook.LimitOrder memory ord = hook.getOrder(orderId);
        assertTrue(ord.isFilled, "order should be filled");
        // Output token is USDC and the stored net output is > 0.
        address outTok = ord.zeroForOne ? ord.token1 : ord.token0;
        uint256 outputAmount = ord.zeroForOne ? uint256(ord.amount1) : uint256(ord.amount0);
        assertEq(outTok, USDC, "output must be USDC");
        assertGt(outputAmount, 0, "output amount > 0");
        console2.log("filled output USDC:", outputAmount);

        // ── Deposit the USDC output into the REAL Aave wrapper ──
        uint256 hookUsdcBefore = IERC20(USDC).balanceOf(address(hook));
        vm.prank(alice);
        hook.depositToVault(orderId);

        ord = hook.getOrder(orderId);
        assertGt(ord.vaultShares, 0, "vault shares recorded after real Aave deposit");
        assertEq(IERC4626(WA_USDC).balanceOf(address(hook)), ord.vaultShares, "hook holds exactly its shares");
        assertEq(hookUsdcBefore - IERC20(USDC).balanceOf(address(hook)), outputAmount, "USDC left the hook into Aave");

        uint256 assetsAtDeposit = IERC4626(WA_USDC).convertToAssets(ord.vaultShares);
        console2.log("assets redeemable at deposit:", assetsAtDeposit);

        // ── Let real Aave interest accrue ──
        vm.warp(block.timestamp + 180 days);

        uint256 assetsAfterWarp = IERC4626(WA_USDC).convertToAssets(ord.vaultShares);
        console2.log("assets redeemable after 180d:", assetsAfterWarp);
        assertGt(assetsAfterWarp, assetsAtDeposit, "REAL Aave yield must accrue over time");

        // ── Claim: redeem from real Aave + pay output (+ self-funded rebate) ──
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 hookBeforeClaim = IERC20(USDC).balanceOf(address(hook));
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey);
        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        uint256 hookGain = IERC20(USDC).balanceOf(address(hook)) - hookBeforeClaim; // un-rebated yield kept

        console2.log("alice received on claim:", received);
        console2.log("un-rebated yield kept by hook:", hookGain);

        // The position is closed (NFT burned) -> the real-Aave redeem succeeded (no VaultRedeemFailed).
        vm.expectRevert();
        hook.ownerOf(orderId);

        // Conservation ties the payout to the REAL accrued yield (not vacuous): everything the hook
        // redeemed from real Aave went either to alice (output + rebate) or stayed as un-rebated yield.
        assertApproxEqAbs(received + hookGain, assetsAfterWarp, 1e4, "redeemed == alice payout + hook surplus");
        assertGt(received + hookGain, outputAmount, "REAL Aave yield was actually captured on redeem");
        assertGe(received, outputAmount, "self-funded payout: alice gets at least her principal");

        // NOTE (roadmap, HIGH): `hookGain` is un-rebated yield (yield beyond the min(yield, IL) rebate).
        // It is solvency-safe surplus, but it currently has NO withdrawal path (it is not pendingFees).
        // With a REAL yield vault this is real stranded USDC — credit it to pendingFees or add an owner
        // sweep before mainnet. This assertion makes the leak visible rather than hidden.
        assertGt(hookGain, 0, "un-rebated yield is retained by the hook with no withdrawal path (roadmap)");
    }

    /// @notice Same lifecycle but a claim BEFORE any warp: redeem returns ~principal, no revert, order closes.
    function test_M2_RealAave_ClaimImmediately_NoYield() public {
        bool sellZeroForOne = !usdcIsCurrency0;
        uint128 trigger = sellZeroForOne ? uint128(1.002e18) : uint128(0.998e18);
        uint96 amountIn = 500e6;

        other.mint(alice, amountIn);
        vm.startPrank(alice);
        other.approve(address(hook), type(uint256).max);
        uint256 orderId = hook.createLimitOrder(poolKey, sellZeroForOne, amountIn, trigger);
        vm.stopPrank();
        _fillSwap(!sellZeroForOne, 10_000e6);

        vm.prank(alice);
        hook.depositToVault(orderId);
        assertGt(hook.getOrder(orderId).vaultShares, 0, "deposited");

        uint256 outputAmount = uint256(sellZeroForOne ? hook.getOrder(orderId).amount1 : hook.getOrder(orderId).amount0);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        hook.claimOrder(orderId, poolKey); // no warp -> real Aave redeem returns ~= principal (rounding aside)
        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        // Redeem returned ~principal from real Aave (no meaningful time passed) — not merely > 0.
        assertApproxEqAbs(received, outputAmount, 1e4, "immediate claim returns ~principal from real Aave");
        vm.expectRevert();
        hook.ownerOf(orderId);
    }

    function _fillSwap(bool zeroForOne, uint256 amount) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
