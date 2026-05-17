// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";

/// @title DeployMainnet - Deploy ILAwareLimitOrderHook to Base or Unichain
/// @notice Reads INITIAL_OWNER (Gnosis Safe) from .env via vm.envAddress
/// @dev Usage:
///   source .env
///
///   # Base:
///   forge script script/DeployMainnet.s.sol:DeployMainnet \
///     --rpc-url $BASE_RPC_URL --broadcast --verify \
///     --etherscan-api-key $BASESCAN_API_KEY \
///     --slow --with-gas-price 100000000 -vvvv
///
///   # Unichain:
///   forge script script/DeployMainnet.s.sol:DeployMainnet \
///     --rpc-url $UNICHAIN_RPC_URL --broadcast --verify \
///     --verifier-url https://api.routescan.io/v2/network/mainnet/evm/130/etherscan/api \
///     --etherscan-api-key $ETHERSCAN_API_KEY \
///     --slow --with-gas-price 100000000 -vvvv
contract DeployMainnet is Script {
    // ========== CHAIN-SPECIFIC POOLMANAGER ADDRESSES ==========
    // Source: https://docs.uniswap.org/contracts/v4/deployments
    address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    // ========== COMPROMISED ADDRESS - NEVER USE AS OWNER ==========
    address constant COMPROMISED_EOA = 0xab4FE51Ba4D5155b2e6842CAD17148b798e4615e;

    // ========== HOOK FLAGS ==========
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    // ========== CREATE2 ==========
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant MAX_ITERATIONS = 100_000_000;

    function run() external {
        // ---- Read env vars ----
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address initialOwner = vm.envAddress("SAFE_OWNER_ADDRESS");

        // ---- Determine PoolManager by chain ID ----
        uint256 chainId = block.chainid;
        address poolManager;

        if (chainId == 8453) {
            poolManager = BASE_POOL_MANAGER;
            console2.log("Chain: Base (8453)");
        } else if (chainId == 130) {
            poolManager = UNICHAIN_POOL_MANAGER;
            console2.log("Chain: Unichain (130)");
        } else {
            revert("Unsupported chain. Expected Base (8453) or Unichain (130)");
        }

        // ---- Safety checks BEFORE deployment ----
        console2.log("\n=== ILAwareLimitOrderHook Mainnet Deployment ===");
        console2.log("Deployer EOA:", deployer);
        console2.log("Initial Owner (Safe):", initialOwner);
        console2.log("PoolManager:", poolManager);

        require(initialOwner != address(0), "SAFE_OWNER_ADDRESS not set in .env");
        require(initialOwner != COMPROMISED_EOA, "CRITICAL: Using compromised EOA as owner!");
        require(initialOwner != deployer, "Owner must be Safe, not deployer EOA");
        require(initialOwner.code.length > 0, "Owner address has no code - not a Safe contract");

        console2.log("Safety checks PASSED");

        // ---- Mine salt ----
        console2.log("\nMining salt...");

        bytes memory creationCode = type(ILAwareLimitOrderHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), initialOwner);
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        address predictedAddr;
        bytes32 salt;
        bool found = false;

        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(i);
            predictedAddr = vm.computeCreate2Address(salt, initCodeHash, CREATE2_DEPLOYER);

            uint160 addrFlags = uint160(predictedAddr) & uint160(0x3FFF);
            if (addrFlags == HOOK_FLAGS) {
                found = true;
                console2.log("Found valid salt:", i);
                console2.log("Predicted address:", predictedAddr);
                console2.log("Address flags:", uint256(addrFlags));
                break;
            }
        }

        require(found, "No valid salt found - try increasing MAX_ITERATIONS");

        // ---- Deploy ----
        vm.startBroadcast(deployerPrivateKey);

        ILAwareLimitOrderHook hook = new ILAwareLimitOrderHook{salt: salt}(
            IPoolManager(poolManager),
            initialOwner,
            address(0) // yieldVault: set to real ERC-4626 vault before production deploy
        );

        vm.stopBroadcast();

        // ---- Post-deploy verification ----
        require(address(hook) == predictedAddr, "CRITICAL: Address mismatch after deploy!");
        require(hook.owner() == initialOwner, "CRITICAL: Owner mismatch - not the Safe!");

        console2.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console2.log("Hook deployed at:", address(hook));
        console2.log("Owner (Safe):", hook.owner());
        console2.log("Fee BPS:", hook.feeBps());
        console2.log("\nDONE. Verify ownership with cast:");
        console2.log("  cast call", address(hook), "\"owner()(address)\" --rpc-url $RPC_URL");
    }
}
