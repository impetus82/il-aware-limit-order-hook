// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @title SetupSepolia - Deploy tokens, init pool, add liquidity on Sepolia
/// @dev Run AFTER DeployTestnet.s.sol. Updates HOOK_ADDRESS before running.
///
///   Usage:
///   source .env
///   forge script script/SetupSepolia.s.sol:SetupSepolia \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   NOTE: Set HOOK_ADDRESS to the output of DeployTestnet before running!
contract SetupSepolia is Script {
    // ========== CONFIGURATION ==========
    // Uniswap V4 PoolManager on Sepolia (from docs.uniswap.org/contracts/v4/deployments)
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // Phase 3.7: Updated to redeployed hook (directional tick scanning fix)
    address constant HOOK_ADDRESS = 0x43BF7DA3d2e26D295a8965109505767e93B24040;

    // Pool parameters
    int24 constant TICK_SPACING = 60;
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price (sqrt(1) * 2^96)

    // Liquidity parameters
    uint256 constant MINT_AMOUNT = 10_000_000 ether; // 10M tokens each
    uint256 constant LIQUIDITY_AMOUNT = 10_000_000 ether; // match liquidity needs
    int24 constant TICK_LOWER = -887220; // near-MIN_TICK, кратно tickSpacing=60
    int24 constant TICK_UPPER = 887220;  // near-MAX_TICK, кратно tickSpacing=60
    int256 constant LIQUIDITY_DELTA = 10_000_000e18; // 10M units - глубокий пул

    function run() external {
        require(HOOK_ADDRESS != address(0), "Set HOOK_ADDRESS before running!");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Sepolia Pool Setup (Phase 3.9 - Full Range) ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:", HOOK_ADDRESS);
        console2.log("PoolManager:", POOL_MANAGER);

        vm.startBroadcast(deployerPrivateKey);

        // ---- Step 1: Deploy Mock Tokens ----
        MockERC20 tokenA = new MockERC20("Test Token A", "TTA", 18);
        MockERC20 tokenB = new MockERC20("Test Token B", "TTB", 18);
        console2.log("TokenA deployed:", address(tokenA));
        console2.log("TokenB deployed:", address(tokenB));

        // ---- Step 2: Sort tokens (currency0 < currency1) ----
        (MockERC20 token0, MockERC20 token1) = address(tokenA) < address(tokenB)
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        console2.log("Token0 (sorted):", address(token0));
        console2.log("Token1 (sorted):", address(token1));

        // ---- Step 3: Mint tokens to deployer ----
        token0.mint(deployer, MINT_AMOUNT);
        token1.mint(deployer, MINT_AMOUNT);
        console2.log("Minted 1M of each token to deployer");

        // ---- Step 4: Deploy PoolModifyLiquidityTest (helper router) ----
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(
            IPoolManager(POOL_MANAGER)
        );
        console2.log("LP Router deployed:", address(lpRouter));

        // ---- Step 5: Build PoolKey ----
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000, // 0.3%
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // ---- Step 6: Initialize Pool ----
        IPoolManager(POOL_MANAGER).initialize(poolKey, INITIAL_SQRT_PRICE);
        console2.log("Pool initialized at sqrtPrice:", uint256(INITIAL_SQRT_PRICE));

        // ---- Step 7: Approve LP Router ----
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        console2.log("Tokens approved for LP Router");

        // ---- Step 8: Add Liquidity ----
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            "" // hookData
        );
        console2.log("Liquidity added! tickLower: -887220, tickUpper: 887220 (full range)");

        vm.stopBroadcast();

        // ---- Summary ----
        console2.log("");
        console2.log("=== SETUP COMPLETE ===");
        console2.log("Token0:", address(token0));
        console2.log("Token1:", address(token1));
        console2.log("LP Router:", address(lpRouter));
        console2.log("Hook:", HOOK_ADDRESS);
        console2.log("Pool Fee: 0.3%, Tick Spacing: 60");
        console2.log("");
        console2.log(">>> COPY Token0 and Token1 addresses into InteractSepolia.s.sol! <<<");
    }
}