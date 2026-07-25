// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title  LiquidityRouterBase — minimal unlock-callback router for adding liquidity on Base
/// @dev    Mirrors LiquidityRouterUnichain: PoolManager calls unlockCallback on THIS contract, which
///         adds full-range liquidity then settles owed tokens via sync → transferFrom(payer) → settle.
///         Currency-agnostic (handles amount0/amount1 by sign), so the same code works for either token
///         orientation. Owner-gated + single-purpose; the deployer approves this router to pull tokens.
contract LiquidityRouterBase is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;
    int256 public immutable liquidityDelta;

    // Full range for tickSpacing = 60.
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    /// @notice Liquidity this router currently holds in the position.
    /// @dev    The v4 position is owned by THIS contract, so without a withdraw path the seed would be
    ///         permanently locked — which is exactly what happened to the first Base seed. Tracked here
    ///         so `removeLiquidity` can never try to burn more than the router actually deployed.
    uint256 public deployed;

    constructor(IPoolManager _poolManager, int256 _liquidityDelta) {
        poolManager = _poolManager;
        owner = msg.sender;
        liquidityDelta = _liquidityDelta;
    }

    function addLiquidity(PoolKey calldata poolKey) external {
        require(msg.sender == owner, "Only owner");
        require(liquidityDelta > 0, "delta must be positive");
        poolManager.unlock(abi.encode(poolKey, msg.sender, liquidityDelta));
        deployed += uint256(liquidityDelta);
    }

    /// @notice Withdraw seeded liquidity (plus any accrued fees) back to the owner.
    /// @param amount Liquidity units to burn; pass `deployed()` to exit fully.
    function removeLiquidity(PoolKey calldata poolKey, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        require(amount > 0 && amount <= deployed, "bad amount");
        deployed -= amount;
        poolManager.unlock(abi.encode(poolKey, msg.sender, -int256(amount)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        (PoolKey memory poolKey, address payer, int256 delta_) = abi.decode(data, (PoolKey, address, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: delta_, salt: bytes32(0)
            }),
            ""
        );
        console2.log("Delta amount0 (currency0):", int256(delta.amount0()));
        console2.log("Delta amount1 (currency1):", int256(delta.amount1()));

        // Negative delta = we owe tokens to the pool: sync, transfer from payer, settle.
        if (delta.amount0() < 0) {
            poolManager.sync(poolKey.currency0);
            IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(
                payer, address(poolManager), uint256(uint128(-delta.amount0()))
            );
            poolManager.settle();
        }
        if (delta.amount1() < 0) {
            poolManager.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(
                payer, address(poolManager), uint256(uint128(-delta.amount1()))
            );
            poolManager.settle();
        }
        // Positive delta = the pool owes us: on removeLiquidity this is the returned principal plus any
        // accrued fees; on addLiquidity it should not occur, but is forwarded to the payer either way.
        if (delta.amount0() > 0) poolManager.take(poolKey.currency0, payer, uint256(uint128(delta.amount0())));
        if (delta.amount1() > 0) poolManager.take(poolKey.currency1, payer, uint256(uint128(delta.amount1())));
        return "";
    }
}

/// @title  SetupPoolBase — initialize the Base WETH/USDC pool for the real-Aave hook + seed liquidity
/// @notice Companion to DeployBaseAave. After the hook is live, this (a) initializes its WETH/USDC pool
///         (only if not already initialized) and (b) adds micro full-range liquidity so the pool is
///         tradeable and orders can fill. Base token sort: WETH (0x4200..) < USDC (0x8335..) →
///         currency0 = WETH, currency1 = USDC (the OPPOSITE of Unichain — do not copy Unichain ticks).
///
///   Usage (Base mainnet):
///     source .env   # DEPLOYER_PRIVATE_KEY; deployer must hold a little WETH + USDC on Base
///     # 1) DRY RUN (no --broadcast):
///     forge script script/SetupPoolBase.s.sol:SetupPoolBase --rpc-url https://mainnet.base.org -vvvv
///     # 2) Broadcast once the simulation looks right:
///     forge script script/SetupPoolBase.s.sol:SetupPoolBase \
///       --rpc-url https://mainnet.base.org --broadcast -vvvv
contract SetupPoolBase is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev DeployBaseAave, real Aave vault. Redeployed 2026-07-25 with the vault-path hardening
    ///      (saturating `_calculateIL`, measured-receipt claim, ZeroSharesMinted). Supersedes
    ///      0x17fE80F8a1ba277B1acd86D1622FaFC20CD254Ce, whose pool is now abandoned.
    address constant HOOK = 0x1afeB37bdC763c1FC8CCB4E30c39BFFe139894Ce;

    // Must match the frontend pool params (contracts.ts POOL_FEE / TICK_SPACING).
    uint24 constant POOL_FEE = 3000; // 0.30%
    int24 constant TICK_SPACING = 60;

    // Initial price ~1866 USDC/WETH. On Base currency0=WETH, so price = USDC_raw/WETH_raw = 1.0001^tick;
    // tick -201000 ≈ 1866 USDC/WETH (mirror-image of Unichain's +201002 where USDC is currency0).
    int24 constant INIT_TICK = -201000;

    /// @dev Micro full-range seed, sized to what the deployer already holds (~0.000033 WETH +
    ///      ~0.061 USDC at the init tick). Enough to make the pool tradeable and let orders fill;
    ///      the pool can be deepened later by calling `addLiquidity` again on the same router, and
    ///      the whole seed is recoverable via `removeLiquidity`.
    int256 constant LIQUIDITY_DELTA = 1.4e9;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Overridable so a freshly redeployed hook can be wired up without editing the constant
        // (mirrors POOL_MANAGER / YIELD_VAULT above).
        address hook = vm.envOr("HOOK", HOOK);

        // Base: currency0 = WETH, currency1 = USDC (WETH sorts first).
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        PoolId id = poolKey.toId();
        uint160 initSqrtPrice = TickMath.getSqrtPriceAtTick(INIT_TICK);

        console2.log("=== SetupPoolBase - WETH/USDC pool for the real-Aave hook ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:    ", hook);
        console2.log("currency0 (WETH):", WETH);
        console2.log("currency1 (USDC):", USDC);
        console2.log("Init tick:", INIT_TICK);

        // ── Pre-flight sanity (view calls, run during simulation) ──
        require(hook.code.length > 0, "SetupPoolBase: hook not deployed (wrong chain?)");
        require(WETH < USDC, "SetupPoolBase: token sort broken (currency0 must be WETH on Base)");

        uint256 wethBal = IERC20(WETH).balanceOf(deployer);
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        console2.log("WETH balance:", wethBal);
        console2.log("USDC balance:", usdcBal);
        // Thresholds sit just above the deterministic seed cost measured on a Base fork
        // (BasePoolSetupForkTest) for LIQUIDITY_DELTA at INIT_TICK. Re-measure if either changes.
        require(wethBal >= 0.000035 ether, "SetupPoolBase: need >= 0.000035 WETH for liquidity");
        require(usdcBal >= 65_000, "SetupPoolBase: need >= 0.065 USDC for liquidity");

        vm.startBroadcast(pk);

        // 1) Initialize the pool (idempotent: skip if already initialized).
        (uint160 existing,,,) = POOL_MANAGER.getSlot0(id);
        if (existing == 0) {
            POOL_MANAGER.initialize(poolKey, initSqrtPrice);
            console2.log("Pool initialized. sqrtPriceX96:", initSqrtPrice);
        } else {
            console2.log("Pool already initialized. sqrtPriceX96:", existing);
        }

        // 2) Deploy the router, approve it to pull tokens, add liquidity.
        LiquidityRouterBase router = new LiquidityRouterBase(POOL_MANAGER, LIQUIDITY_DELTA);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.addLiquidity(poolKey);

        // Revoke the router's pull allowance — it is single-use, so leave no lingering approval.
        IERC20(WETH).approve(address(router), 0);
        IERC20(USDC).approve(address(router), 0);

        vm.stopBroadcast();

        console2.log("\n=== POOL LIVE ===");
        console2.log("Router:", address(router));
        console2.log("WETH spent:", wethBal - IERC20(WETH).balanceOf(deployer));
        console2.log("USDC spent:", usdcBal - IERC20(USDC).balanceOf(deployer));
        console2.log("Active liquidity:", POOL_MANAGER.getLiquidity(id));
        console2.log("PoolId (put this in frontend contracts.ts, chain 8453):");
        console2.logBytes32(PoolId.unwrap(id));
    }
}
