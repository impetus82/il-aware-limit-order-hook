// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./HookMiner.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";

/// @title  PredictBaseRedeploy — KEYLESS prediction of the redeployed Base hook address + poolId.
/// @notice Uses only the PUBLIC deployer address (no private key, no broadcast, no RPC needed), so it
///         can be run to verify what `DeployBaseAave` WILL produce before the real broadcast. The Base
///         hook address is deterministic — the vault (waBasUSDC) is a constant, so
///         address = f(factory, flags, creationCode, abi.encode(poolManager, deployer, vault)). This is
///         NOT possible on Unichain, where DeployHookathon deploys a fresh vault whose address (hence the
///         hook's constructor args) is only known at broadcast time.
///
///   Usage:  forge script script/PredictBaseRedeploy.s.sol           # uses the known deployer
///           DEPLOYER_ADDRESS=0x... forge script script/PredictBaseRedeploy.s.sol   # override
contract PredictBaseRedeploy is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant WA_BAS_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6; // real Aave, asset = USDC
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant DEFAULT_DEPLOYER = 0x8114cdc7dDEa2Be36435351dB2115887daEF5e12;

    // Same 7 flags DeployBaseAave mines for (low 14 bits of the address must equal 0x14CE).
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", DEFAULT_DEPLOYER);

        bytes memory constructorArgs = abi.encode(POOL_MANAGER, deployer, WA_BAS_USDC);
        (address hook, bytes32 salt) =
            HookMiner.find(HOOK_CREATE2_FACTORY, FLAGS, type(ILAwareLimitOrderHook).creationCode, constructorArgs);
        require((uint160(hook) & 0x3FFF) == FLAGS, "flags mismatch");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        bytes32 poolId = PoolId.unwrap(poolKey.toId());

        console2.log("=== Predicted Base redeploy (deployer/owner =", deployer, ") ===");
        console2.log("Hook:  ", hook);
        console2.log("Salt:  ", vm.toString(salt));
        console2.log("PoolId:", vm.toString(poolId));
    }
}
