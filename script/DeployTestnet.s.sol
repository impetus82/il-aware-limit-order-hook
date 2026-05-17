// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";

/// @title DeployTestnet — Deploy ILAwareLimitOrderHook to Sepolia
/// @dev Usage:
///   source .env
///   forge script script/DeployTestnet.s.sol:DeployTestnet \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify \
///     --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
contract DeployTestnet is Script {
    // Uniswap V4 PoolManager Canonical Singleton
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // beforeSwap + beforeSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    // Foundry's deterministic CREATE2 deployer used by `forge script`
    // See: https://github.com/Arachnid/deterministic-deployment-proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 constant MAX_ITERATIONS = 100_000_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== ILAwareLimitOrderHook Sepolia Deployment ===");
        console2.log("Deployer EOA:", deployer);
        console2.log("CREATE2 Deployer:", CREATE2_DEPLOYER);
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("Required flags:", uint256(HOOK_FLAGS));

        // ---- Mine salt ----
        // forge script routes `new Foo{salt: s}(...)` through CREATE2_DEPLOYER,
        // so we must compute the address with CREATE2_DEPLOYER as origin.
        console2.log("\nMining salt...");

        bytes memory creationCode = type(ILAwareLimitOrderHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), deployer);
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

        require(found, "No valid salt found");

        // ---- Deploy ----
        vm.startBroadcast(deployerPrivateKey);

        ILAwareLimitOrderHook hook = new ILAwareLimitOrderHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            deployer,
            address(0) // yieldVault: address(0) for testnet
        );

        vm.stopBroadcast();

        // ---- Verify ----
        require(address(hook) == predictedAddr, "Deploy: address mismatch!");

        console2.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console2.log("Hook deployed at:", address(hook));
        console2.log("Owner:", hook.owner());

        console2.log("\n--- Verify on Etherscan ---");
        console2.log(
            "forge verify-contract",
            address(hook),
            "src/ILAwareLimitOrderHook.sol:ILAwareLimitOrderHook --chain sepolia"
        );
    }
}
