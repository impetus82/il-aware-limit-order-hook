// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title SetupBase — Initialize WETH/USDC pool with ILAwareLimitOrderHook on Base Mainnet
/// @notice This script ONLY calls poolManager.initialize().
///         It does NOT mint tokens and does NOT add liquidity (real money — do that manually).
///
/// @dev Usage:
///   source .env
///
///   # Dry-run first:
///   forge script script/SetupBase.s.sol:SetupBase \
///     --rpc-url $BASE_RPC_URL -vvvv
///
///   # Then broadcast:
///   forge script script/SetupBase.s.sol:SetupBase \
///     --rpc-url $BASE_RPC_URL --broadcast \
///     --slow --with-gas-price 100000000 -vvvv
contract SetupBase is Script {
    using PoolIdLibrary for PoolKey;

    // ========== BASE MAINNET ADDRESSES ==========
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HOOK_ADDRESS = 0x02C72A5E1125AD6f4B8D71E87af14BC8663b0040;

    // Token addresses on Base
    // WETH: 0x4200... < USDC: 0x8335...  →  currency0 = WETH, currency1 = USDC
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Pool parameters (must match frontend config)
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000; // 0.3%

    // ========== STARTING PRICE ==========
    // 1 WETH = 3500 USDC
    //
    // currency0 = WETH (18 decimals), currency1 = USDC (6 decimals)
    // price_raw = 3500 * 10^6 / 10^18 = 3.5e-9
    // sqrtPriceX96 = sqrt(3.5e-9) * 2^96 = 4687201305027700636778496
    //
    // To recalculate for a different price P (1 WETH = P USDC):
    //   sqrtPriceX96 = sqrt(P) * 2^96 / 10^6
    //
    // Verification: (4687201305027700636778496 / 2^96)^2 * 10^12 = 3500.0 ✅
    uint160 constant INITIAL_SQRT_PRICE = 4687201305027700636778496;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Base Mainnet Pool Setup (Phase 5.6) ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:", HOOK_ADDRESS);
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("");

        // ---- Safety: verify token sorting ----
        require(WETH < USDC, "Token sort error: WETH must be < USDC");
        console2.log("currency0 (WETH):", WETH);
        console2.log("currency1 (USDC):", USDC);

        // ---- Build PoolKey ----
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // ---- Compute and log PoolId ----
        PoolId poolId = poolKey.toId();
        console2.log("");
        console2.log("PoolId (bytes32) - COPY THIS FOR FRONTEND:");
        console2.logBytes32(PoolId.unwrap(poolId));

        // ---- Log starting price info ----
        int24 startTick = TickMath.getTickAtSqrtPrice(INITIAL_SQRT_PRICE);
        console2.log("");
        console2.log("Starting sqrtPriceX96:", uint256(INITIAL_SQRT_PRICE));
        console2.log("Starting tick:", startTick);
        console2.log("Human price: 1 WETH = ~3500 USDC");

        // ---- Initialize Pool ----
        vm.startBroadcast(deployerPrivateKey);

        IPoolManager(POOL_MANAGER).initialize(poolKey, INITIAL_SQRT_PRICE);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== POOL INITIALIZED SUCCESSFULLY ===");
        console2.log("Pool Fee: 0.3%, Tick Spacing: 60");
        console2.log("Hook:", HOOK_ADDRESS);
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("1. Copy the PoolId above into frontend/src/config/contracts.ts");
        console2.log("2. Add liquidity via Uniswap UI or a separate script");
        console2.log("3. Update frontend tokens from TTA/TTB to WETH/USDC");
        console2.log("4. Deploy frontend update to Vercel");
    }
}