// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @title LiquidityRouterUnichain - recoverable unlock-callback router for USDC/WETH on Unichain
/// @dev PoolManager calls unlockCallback on THIS contract (not the EOA). Mirrors LiquidityRouterBase:
///      adds/removes full-range liquidity, settling owed tokens (sync → transferFrom(payer) → settle)
///      or taking returned tokens. Currency-agnostic (handles amount0/amount1 by sign). Owner-gated.
///      The v4 position is owned by THIS contract, so `removeLiquidity` is the ONLY exit — without it
///      the seed would be permanently locked (as the first Base seed was). Unichain: currency0 = USDC.
contract LiquidityRouterUnichain is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;
    int256 public immutable liquidityDelta;

    // Full range ticks (tickSpacing=60)
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    /// @notice Liquidity this router currently holds in the position (guards removeLiquidity).
    uint256 public deployed;

    constructor(IPoolManager _poolManager, int256 _liquidityDelta) {
        poolManager = _poolManager;
        owner = msg.sender;
        liquidityDelta = _liquidityDelta;
    }

    /// @notice Add liquidity: approve this router for tokens, then call this
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

    /// @notice Callback from PoolManager.unlock()
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

        // Unichain: amount0 = USDC delta, amount1 = WETH delta
        console2.log("Delta amount0 (USDC):", int256(delta.amount0()));
        console2.log("Delta amount1 (WETH):", int256(delta.amount1()));

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

/// @title AddLiquidityUnichain - Add micro liquidity to USDC/WETH pool on Unichain
/// @notice Deploys a LiquidityRouterUnichain on-chain, approves it, then adds liquidity
/// @dev The router contract receives the unlockCallback (not the EOA).
///      Unichain token sort: currency0 = USDC (0x078d...) < currency1 = WETH (0x4200...)
///
///   Usage:
///     source .env
///     forge script script/AddLiquidityUnichain.s.sol:AddLiquidityUnichain \
///       --rpc-url https://mainnet.unichain.org --broadcast \
///       --with-gas-price 100000000 -vvvv
contract AddLiquidityUnichain is Script {
    // ── Addresses (Unichain Mainnet) ────────────────────────
    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);

    // Unichain: USDC sorts before WETH → currency0 = USDC, currency1 = WETH
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant HOOK = 0x8C19f1641946c662308000bB4E2Eaf684c81d4CE; // Phase 6.19 redeploy (SimulatedYieldVault)

    // ── Pool parameters (must match pool initialization) ────
    uint24 constant POOL_FEE = 3000; // 0.30% — matches pool initialized via DeployHookathon.s.sol
    int24 constant TICK_SPACING = 60;

    /// @dev Seed size, passed to the router which owns the position (recoverable via removeLiquidity).
    int256 constant LIQUIDITY_DELTA = 1e10;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        // Overridable so a freshly redeployed Unichain hook can be wired up without editing the
        // constant — its address is unknown until DeployHookathon broadcasts the fresh vault + hook.
        address hookAddr = vm.envOr("HOOK", HOOK);

        console2.log("=== Add Liquidity to Unichain USDC/WETH Pool ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:    ", hookAddr);
        require(hookAddr.code.length > 0, "AddLiquidityUnichain: hook not deployed (wrong chain?)");

        // Unichain: currency0 = USDC, currency1 = WETH
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        // Check balances
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        uint256 wethBal = IERC20(WETH).balanceOf(deployer);
        console2.log("USDC balance:", usdcBal);
        console2.log("WETH balance:", wethBal);

        require(usdcBal >= 5e5, "Need at least 0.5 USDC");
        require(wethBal >= 0.0002 ether, "Need at least 0.0002 WETH");

        vm.startBroadcast(deployerPk);

        // 1. Deploy router contract on-chain
        LiquidityRouterUnichain router = new LiquidityRouterUnichain(POOL_MANAGER, LIQUIDITY_DELTA);
        console2.log("Router deployed at:", address(router));

        // 2. Approve router to pull tokens from deployer (for transferFrom in callback)
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(WETH).approve(address(router), type(uint256).max);

        // 3. Also approve PoolManager directly (router uses transferFrom deployer->PM)
        IERC20(USDC).approve(address(POOL_MANAGER), type(uint256).max);
        IERC20(WETH).approve(address(POOL_MANAGER), type(uint256).max);

        // 4. Call router to add liquidity (router receives the callback)
        router.addLiquidity(poolKey);

        vm.stopBroadcast();

        // Check balances after
        uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
        uint256 wethAfter = IERC20(WETH).balanceOf(deployer);
        console2.log("\n=== LIQUIDITY ADDED ===");
        console2.log("USDC spent:", usdcBal - usdcAfter);
        console2.log("WETH spent:", wethBal - wethAfter);
    }
}
