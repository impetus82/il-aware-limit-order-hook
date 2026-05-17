// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {console2} from "forge-std/console2.sol"; // <-- Добавить для отладки

/// @title HookMiner
/// @notice Library for mining hook addresses with required permissions via CREATE2
/// @dev Iterates through salts to find an address matching the required flags
library HookMiner {
    /// @notice Maximum iterations for mining (increase if needed)
    uint256 constant MAX_ITERATIONS = 1_000_000; // <-- Увеличить до 1M
    
    /// @notice Find a salt that produces a hook address with the desired flags
    /// @param deployer The address that will deploy the hook
    /// @param flags The hook permissions encoded as uint160
    /// @param creationCode The contract creation bytecode
    /// @param constructorArgs The ABI-encoded constructor arguments
    /// @return hookAddress The address that will be deployed
    /// @return salt The salt that produces the desired address
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) { // <-- pure вместо view
        // Compute initCodeHash once
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);
        
        // Mine for a valid address
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(i);
            hookAddress = computeCreate2Address(deployer, salt, initCodeHash);
            
            // Check if address matches required flags
            if (isValidAddress(hookAddress, flags)) {
                // Log success (only works in tests with forge-std)
                return (hookAddress, salt);
            }
        }
        
        // If we reach here, no valid address found
        revert("HookMiner: no valid address found");
    }
    
    /// @notice Compute CREATE2 address
    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
    
    /// @notice Check if an address matches the required hook flags
    /// @param addr The address to check
    /// @param flags The required flags (bitmask)
    /// @return True if the address has all required flags set
    function isValidAddress(address addr, uint160 flags) internal pure returns (bool) {
        // Extract the last 14 bits of the address (hook permissions)
        uint160 addressFlags = uint160(addr) & uint160(0x3FFF);
        
        // Check if all required flags are present
        return addressFlags == flags;
    }
    
    /// @notice Helper to display address flags (for debugging)
    function getAddressFlags(address addr) internal pure returns (uint160) {
        return uint160(addr) & uint160(0x3FFF);
    }
}