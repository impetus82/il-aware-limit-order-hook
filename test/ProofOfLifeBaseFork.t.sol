// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {SwapRouterBase} from "../script/ProofOfLifeBase.s.sol";

/// @notice Fork Base and run the FULL proof-of-life lifecycle against the REAL live hook + pool:
///         place a SELL-WETH order, trigger it with a tiny USDC→WETH swap (hook self-fills in
///         afterSwap), then claim the USDC output. Calibrates the micro amounts so the real broadcast
///         is known-good. Opt-in (RUN_FORK_TESTS=1).
///
/// Run: RUN_FORK_TESTS=1 forge test --match-contract ProofOfLifeBaseForkTest -vv
contract ProofOfLifeBaseForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // Mirror ProofOfLifeBase.s.sol.
    uint96 constant ORDER_WETH = 2e13; // 0.00002 WETH
    uint256 constant SWAP_USDC = 3e3; //  0.003 USDC
    uint128 constant TRIGGER = 1_869_000_000;

    PoolKey poolKey;

    function setUp() public {
        if (vm.envOr("RUN_FORK_TESTS", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("base");
        poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function test_Base_ProofOfLife_CreateTriggerFillClaim() public {
        assertGt(HOOK.code.length, 0, "hook must be live on Base");

        // Fund this contract with a little real WETH + USDC (like the deployer holds).
        deal(WETH, address(this), 1e15); // 0.001 WETH
        deal(USDC, address(this), 1e6); //  1 USDC

        // 1) Place a SELL-WETH order with a trigger just above spot.
        IERC20(WETH).approve(HOOK, ORDER_WETH);
        uint256 orderId = ILAwareLimitOrderHook(HOOK).createLimitOrder(poolKey, true, ORDER_WETH, TRIGGER);
        assertEq(ILAwareLimitOrderHook(HOOK).ownerOf(orderId), address(this), "order minted to us");

        // 2) Trigger: tiny USDC->WETH swap pushes price up across the trigger; hook fills in afterSwap.
        SwapRouterBase router = new SwapRouterBase(POOL_MANAGER);
        IERC20(USDC).approve(address(router), SWAP_USDC);
        router.swap(poolKey, false, -int256(SWAP_USDC), TickMath.MAX_SQRT_PRICE - 1);

        ILAwareLimitOrderHook.LimitOrder memory o = ILAwareLimitOrderHook(HOOK).getOrder(orderId);
        assertTrue(o.isFilled, "order must self-fill once the swap crosses its trigger");
        assertGt(uint256(o.amount1), 0, "filled order must have a claimable USDC output");
        console2.log("Filled. Claimable USDC output:", uint256(o.amount1));

        // 3) Claim the output (no vault path — pure output payout).
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        ILAwareLimitOrderHook(HOOK).claimOrder(orderId, poolKey);
        uint256 got = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        assertGt(got, 0, "claim must pay out the USDC output");
        console2.log("Claimed USDC:", got);

        // Order NFT is burned after claim.
        vm.expectRevert();
        ILAwareLimitOrderHook(HOOK).ownerOf(orderId);
    }
}
