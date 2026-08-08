// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {LiquidityRouterUnichain} from "../script/AddLiquidityUnichain.s.sol";

/// @notice Fork Unichain mainnet and validate `AddLiquidityUnichain`'s init + add-liquidity logic —
///         crucially the PRICE ORIENTATION (currency0 = USDC, so INIT_TICK = +201002 ≈ 1866 USDC/WETH,
///         the mirror of Base's -201000) and the seed's recoverability. Deploys a FRESH hook so the
///         init path (afterInitialize on real bytecode) is exercised, not just add-liquidity.
///         Opt-in (RUN_FORK_TESTS=1) so the default offline suite is untouched.
///
/// Run: RUN_FORK_TESTS=1 forge test --match-contract UnichainPoolSetupForkTest -vv
contract UnichainPoolSetupForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Real Unichain mainnet addresses (must match AddLiquidityUnichain.s.sol).
    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant INIT_TICK = 201002; // currency0 = USDC → ~1866 USDC/WETH (mirror of Base -201000)
    int256 constant LIQUIDITY_DELTA = 1.4e9; // keep in sync with AddLiquidityUnichain.s.sol

    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        if (vm.envOr("RUN_FORK_TESTS", uint256(0)) == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("unichain"); // latest Unichain block via foundry.toml [rpc_endpoints]
    }

    function test_Unichain_InitPoolAndAddLiquidity() public {
        assertTrue(USDC < WETH, "currency0 must be USDC on Unichain");

        // Deploy a fresh hardened hook (vault disabled — irrelevant to pool init/seed) at a flag-valid
        // CREATE2 address, exactly as DeployHookathon would, but with a throwaway vault.
        bytes memory args = abi.encode(POOL_MANAGER, address(this), address(0));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(ILAwareLimitOrderHook).creationCode, args);
        ILAwareLimitOrderHook hook =
            new ILAwareLimitOrderHook{salt: salt}(POOL_MANAGER, address(this), address(0));
        assertEq(address(hook), expected, "mined hook address mismatch");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId id = poolKey.toId();

        deal(WETH, address(this), 1 ether);
        deal(USDC, address(this), 10_000e6);

        // 1) Initialize the fresh pool at INIT_TICK — runs the hook's real afterInitialize.
        POOL_MANAGER.initialize(poolKey, TickMath.getSqrtPriceAtTick(INIT_TICK));
        (uint160 sqrtAfterInit, int24 tickAfterInit,,) = POOL_MANAGER.getSlot0(id);
        assertGt(uint256(sqrtAfterInit), 0, "pool must be initialized");
        assertEq(tickAfterInit, INIT_TICK, "pool initialized at the intended tick");

        // 2) Deploy the REAL script router, approve, add liquidity through the hooked pool.
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        LiquidityRouterUnichain router = new LiquidityRouterUnichain(POOL_MANAGER, LIQUIDITY_DELTA);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);
        router.addLiquidity(poolKey);

        assertGe(uint256(POOL_MANAGER.getLiquidity(id)), uint256(LIQUIDITY_DELTA), "active liquidity present");

        uint256 wethSpent = wethBefore - IERC20(WETH).balanceOf(address(this));
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(address(this));
        assertGt(wethSpent, 0, "WETH pulled for liquidity");
        assertGt(usdcSpent, 0, "USDC pulled for liquidity");
        // ORIENTATION GUARD: at ~1866 USDC/WETH the 1.4e9 seed costs ~0.000033 WETH + ~0.061 USDC.
        // A flipped tick sign (or wrong currency order) would blow these micro bounds apart.
        assertLt(wethSpent, 0.0002 ether, "WETH spend stays micro (orientation sane)");
        assertLt(usdcSpent, 1e6, "USDC spend stays micro (orientation sane)");

        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("WETH spent:", wethSpent);
        console2.log("USDC spent:", usdcSpent);

        // 3) The seed must be RECOVERABLE (the old Unichain router had no exit → stranded seed).
        uint256 wethMid = IERC20(WETH).balanceOf(address(this));
        uint256 usdcMid = IERC20(USDC).balanceOf(address(this));
        uint256 liqMid = POOL_MANAGER.getLiquidity(id);
        router.removeLiquidity(poolKey, router.deployed());

        assertEq(router.deployed(), 0, "router should hold no liquidity after a full exit");
        assertGt(IERC20(WETH).balanceOf(address(this)) - wethMid, 0, "WETH returned to owner");
        assertGt(IERC20(USDC).balanceOf(address(this)) - usdcMid, 0, "USDC returned to owner");
        assertEq(
            liqMid - POOL_MANAGER.getLiquidity(id),
            uint256(LIQUIDITY_DELTA),
            "exactly this router's own seed must leave the pool"
        );
    }
}
