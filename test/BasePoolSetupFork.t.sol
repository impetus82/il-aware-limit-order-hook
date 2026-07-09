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
import {LiquidityRouterBase} from "../script/SetupPoolBase.s.sol";

/// @notice Fork Base mainnet and validate `SetupPoolBase`'s init + add-liquidity logic against the REAL
///         deployed hook (`0x17fE80…`), the REAL Base PoolManager, and REAL WETH/USDC — using the exact
///         `LiquidityRouterBase` the script broadcasts. Opt-in (RUN_FORK_TESTS=1) so the default offline
///         suite is untouched.
///
/// Run: RUN_FORK_TESTS=1 forge test --match-contract BasePoolSetupForkTest -vv
contract BasePoolSetupForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Real Base mainnet addresses (must match SetupPoolBase.s.sol).
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x17fE80F8a1ba277B1acd86D1622FaFC20CD254Ce; // DeployBaseAave, real Aave vault
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant INIT_TICK = -201000; // ~1866 USDC/WETH (currency0 = WETH on Base)
    int256 constant LIQUIDITY_DELTA = 1e10;

    function setUp() public {
        if (vm.envOr("RUN_FORK_TESTS", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("base"); // latest Base block via foundry.toml [rpc_endpoints] base
    }

    /// @notice The script's core: initialize the hooked WETH/USDC pool + seed micro full-range liquidity.
    ///         Asserts the pool goes live and both tokens are pulled in micro amounts through the real
    ///         deployed hook (which runs its afterInitialize / afterAddLiquidity on the real bytecode).
    function test_Base_InitPoolAndAddLiquidity() public {
        // The production hook is live on Base, and the Base token sort puts WETH as currency0.
        assertGt(HOOK.code.length, 0, "hook must be deployed on Base");
        assertTrue(WETH < USDC, "currency0 must be WETH on Base");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        PoolId id = poolKey.toId();

        // Fund this contract with a little real WETH + USDC (far more than the micro liquidity needs).
        deal(WETH, address(this), 1 ether);
        deal(USDC, address(this), 1_000e6);

        // 1) Initialize the pool if not already (idempotent, mirrors the script). Runs the hook's
        //    real afterInitialize on-chain-bytecode.
        (uint160 existing,,,) = POOL_MANAGER.getSlot0(id);
        if (existing == 0) {
            POOL_MANAGER.initialize(poolKey, TickMath.getSqrtPriceAtTick(INIT_TICK));
        }
        (uint160 sqrtAfterInit, int24 tickAfterInit,,) = POOL_MANAGER.getSlot0(id);
        assertGt(uint256(sqrtAfterInit), 0, "pool must be initialized");
        if (existing == 0) {
            assertEq(tickAfterInit, INIT_TICK, "pool initialized at the intended tick");
        }

        // 2) Deploy the REAL script router, approve, add liquidity through the hooked pool.
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        LiquidityRouterBase router = new LiquidityRouterBase(POOL_MANAGER, LIQUIDITY_DELTA);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.addLiquidity(poolKey);

        // 3) Pool is live and tradeable: active liquidity present, both tokens pulled in micro amounts.
        assertGe(
            uint256(POOL_MANAGER.getLiquidity(id)),
            uint256(LIQUIDITY_DELTA),
            "active full-range liquidity must be at least what we added"
        );
        uint256 wethSpent = wethBefore - IERC20(WETH).balanceOf(address(this));
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(address(this));
        assertGt(wethSpent, 0, "WETH pulled for liquidity");
        assertGt(usdcSpent, 0, "USDC pulled for liquidity");
        assertLt(wethSpent, 0.01 ether, "WETH spend stays micro");
        assertLt(usdcSpent, 100e6, "USDC spend stays micro");

        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("WETH spent:", wethSpent);
        console2.log("USDC spent:", usdcSpent);
        console2.log("Active liquidity:", POOL_MANAGER.getLiquidity(id));
    }
}
