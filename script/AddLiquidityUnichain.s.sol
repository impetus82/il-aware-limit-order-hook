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

/// @title LiquidityRouterUnichain - On-chain router for PoolManager unlock callback
/// @dev Deployed by the script; PoolManager calls unlockCallback on THIS contract (not the EOA)
/// @notice Unichain: currency0 = USDC (6 dec), currency1 = WETH (18 dec)
contract LiquidityRouterUnichain is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;

    // Full range ticks (tickSpacing=60)
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // Micro liquidity: ~$0.10 at 3500 USDC/WETH
    int256 constant LIQUIDITY_DELTA = 1e10;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    /// @notice Add liquidity: approve this router for tokens, then call this
    function addLiquidity(PoolKey calldata poolKey) external {
        require(msg.sender == owner, "Only owner");
        bytes memory callbackData = abi.encode(poolKey, msg.sender);
        poolManager.unlock(callbackData);
    }

    /// @notice Callback from PoolManager.unlock()
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        (PoolKey memory poolKey, address payer) = abi.decode(data, (PoolKey, address));

        // Add liquidity
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );

        // Unichain: amount0 = USDC delta, amount1 = WETH delta
        console2.log("Delta amount0 (USDC):", int256(delta.amount0()));
        console2.log("Delta amount1 (WETH):", int256(delta.amount1()));

        // Settle: pay tokens owed to PoolManager
        // Negative delta = we owe tokens to pool
        if (delta.amount0() < 0) {
            uint256 owed0 = uint256(uint128(-delta.amount0()));
            poolManager.sync(poolKey.currency0);
            IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(
                payer, address(poolManager), owed0
            );
            poolManager.settle();
        }
        if (delta.amount1() < 0) {
            uint256 owed1 = uint256(uint128(-delta.amount1()));
            poolManager.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(
                payer, address(poolManager), owed1
            );
            poolManager.settle();
        }

        // Take any positive delta (shouldn't happen on add liquidity)
        if (delta.amount0() > 0) {
            poolManager.take(poolKey.currency0, payer, uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            poolManager.take(poolKey.currency1, payer, uint256(uint128(delta.amount1())));
        }

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
    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x1F98400000000000000000000000000000000004);

    // Unichain: USDC sorts before WETH → currency0 = USDC, currency1 = WETH
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant HOOK = 0x9138F699F5F5AB19ed8271c3B143B229781A8040;

    // ── Pool parameters (must match pool initialization) ────
    uint24 constant POOL_FEE = 0; // Dynamic fee via hook
    int24 constant TICK_SPACING = 60;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Add Liquidity to Unichain USDC/WETH Pool ===");
        console2.log("Deployer:", deployer);

        // Unichain: currency0 = USDC, currency1 = WETH
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
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
        LiquidityRouterUnichain router = new LiquidityRouterUnichain(POOL_MANAGER);
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