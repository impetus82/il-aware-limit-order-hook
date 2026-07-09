// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title  DeployBaseAave — production deploy of ILAwareLimitOrderHook on Base with a REAL Aave vault
/// @notice Unlike DeployHookathon (Unichain + the demo SimulatedYieldVault), this points `yieldVault` at
///         the real Aave USDC Static aToken on Base — waBasUSDC, an ERC-4626 StataTokenV2 whose asset() is
///         USDC — so the auto-yield rebate is funded by real lending yield, not a block.timestamp
///         simulation. NO demo vault is deployed here. `yieldVault` is immutable in the hook, so pointing
///         at real Aave is a fresh deploy (redeploy), not an upgrade of the existing Base hook.
///
/// The hook logic is unchanged and vault-agnostic (it only ever calls the ERC-4626 interface); the
/// real-Aave lifecycle is proven end-to-end by test/ILAwareLimitOrderHookAaveFork.t.sol.
///
/// Usage (Base mainnet — DRY RUN first, then broadcast):
///   source .env
///   # 1) simulate (no state change): omit --broadcast
///   forge script script/DeployBaseAave.s.sol:DeployBaseAave --rpc-url https://mainnet.base.org -vvvv
///   # 2) broadcast + verify once the simulation looks right
///   forge script script/DeployBaseAave.s.sol:DeployBaseAave \
///     --rpc-url https://mainnet.base.org --broadcast --verify -vvvv
///
/// Required .env:
///   DEPLOYER_PRIVATE_KEY — deployer EOA private key (becomes the hook owner)
/// Optional .env (defaults shown):
///   POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b  (Base v4 PoolManager)
///   YIELD_VAULT  = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6  (waBasUSDC, asset = USDC)
///
/// Pool orientation note: on Base, WETH (0x4200...0006) < USDC (0x8335...2913), so a WETH/USDC pool has
/// currency0 = WETH, currency1 = USDC. The vault path deposits the order's USDC OUTPUT, so only orders
/// whose output is USDC route into Aave; other orders simply skip the vault path and remain fully
/// functional. (On Unichain currency0 = USDC instead — do not copy Unichain pool assumptions here.)
contract DeployBaseAave is Script {
    /// @dev Base v4 PoolManager.
    IPoolManager constant BASE_POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    /// @dev Real Aave USDC Static aToken on Base (ERC-4626 StataTokenV2); asset() == Base USDC.
    address constant WA_BAS_USDC = 0xC768c589647798a6EE01A91FdE98EF2ed046DBD6;

    /// @dev Base native USDC (6 decimals) — the waBasUSDC underlying, cross-checked at deploy time.
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Deterministic CREATE2 factory (EIP-2470 / Nick's factory — same address on every chain).
    ///      Must be the `deployer` arg to HookMiner.find() so the mined address matches the on-chain
    ///      `new Contract{salt:}()` route Foundry uses during broadcast.
    address constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // 7 hook flags (low 14 bits of the address must equal 0x14CE). IDENTICAL to the Unichain deploy —
    // the permission set is the same regardless of chain or vault.
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", address(BASE_POOL_MANAGER)));
        address yieldVault = vm.envOr("YIELD_VAULT", WA_BAS_USDC);

        console2.log("=== ILAwareLimitOrderHook - Base production deploy (real Aave vault) ===");
        console2.log("Deployer:     ", deployer);
        console2.log("PoolManager:  ", address(poolManager));
        console2.log("yieldVault:   ", yieldVault);
        console2.log("Hook flags:   ", FLAGS);

        // ── Pre-flight sanity (all view calls; run during simulation, BEFORE any broadcast) ──
        // Fail LOUD here rather than deploying a hook wired to the wrong chain or a non-vault address.
        require(address(poolManager).code.length > 0, "DeployBaseAave: PoolManager has no code (wrong chain?)");
        require(yieldVault.code.length > 0, "DeployBaseAave: yieldVault has no code");
        // Confirm yieldVault really is an ERC-4626 (this reverts the simulation if it is not) and log
        // its underlying so the operator can eyeball it before broadcasting.
        address vaultAsset = IERC4626(yieldVault).asset();
        require(vaultAsset != address(0), "DeployBaseAave: yieldVault.asset() is zero");
        console2.log("yieldVault.asset():", vaultAsset);
        if (yieldVault == WA_BAS_USDC) {
            require(vaultAsset == BASE_USDC, "DeployBaseAave: waBasUSDC asset() != Base USDC (address drift?)");
        }

        // ── Mine the CREATE2 salt for a flag-carrying hook address (pure simulation, no broadcast) ──
        bytes memory constructorArgs = abi.encode(poolManager, deployer, yieldVault);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(HOOK_CREATE2_FACTORY, FLAGS, type(ILAwareLimitOrderHook).creationCode, constructorArgs);
        require((uint160(expectedHook) & 0x3FFF) == FLAGS, "DeployBaseAave: mined address flags mismatch");
        console2.log("Salt:         ", vm.toString(salt));
        console2.log("Expected hook:", expectedHook);

        // ── Deploy the hook via CREATE2 ──
        vm.startBroadcast(deployerPk);
        ILAwareLimitOrderHook hook = new ILAwareLimitOrderHook{salt: salt}(poolManager, deployer, yieldVault);
        vm.stopBroadcast();

        // ── Post-deploy invariants ──
        require(address(hook) == expectedHook, "DeployBaseAave: deployed address != mined address");
        require((uint160(address(hook)) & 0x3FFF) == FLAGS, "DeployBaseAave: deployed address flags mismatch");
        require(hook.yieldVault() == yieldVault, "DeployBaseAave: yieldVault mismatch post-deploy");
        require(hook.owner() == deployer, "DeployBaseAave: owner mismatch post-deploy");

        console2.log("\n========================================");
        console2.log("=== DEPLOYMENT COMPLETE (Base) ===");
        console2.log("========================================");
        console2.log("Hook address: ", address(hook));
        console2.log("Hook owner:   ", hook.owner());
        console2.log("yieldVault:   ", hook.yieldVault());
        console2.log("vault asset:  ", vaultAsset, "(real Aave USDC, yield is REAL)");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Initialize a WETH/USDC pool with this hook (currency0=WETH on Base)");
        console2.log("  2. Update frontend/src/config/contracts.ts (8453 hook) + README addresses");
        console2.log("  3. Drop the 'simulated APY' vault label for Base - the yield is now real");
    }
}
