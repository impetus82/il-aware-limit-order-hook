// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {HookMiner} from "./HookMiner.sol";

// ============================================================
//  MOCK YIELD VAULT (Hookathon testnet only)
// ============================================================

/// @notice Minimal ERC-4626 compatible vault for Hookathon demonstration.
///         Stores deposited assets and returns them on redeem — yield
///         can be seeded manually by sending extra tokens to the vault.
contract MockYieldVault {
    IERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    /// @notice Deposit assets, receive 1:1 shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        sharesOf[receiver] += shares;
    }

    /// @notice Redeem shares for assets (any yield from manual top-up is included)
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(sharesOf[owner] >= shares, "MockYieldVault: insufficient shares");
        sharesOf[owner] -= shares;
        // Pro-rata: assets = shares * vaultBalance / totalShares
        // Simplified: 1:1 + any surplus sitting in the vault
        uint256 vaultBalance = asset.balanceOf(address(this));
        assets = shares <= vaultBalance ? shares : vaultBalance;
        asset.transfer(receiver, assets);
    }

    /// @notice ERC-4626 minimal metadata
    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

// ============================================================
//  DEPLOY SCRIPT
// ============================================================

/// @title  DeployHookathon — One-shot deployment for UHI9 on Unichain
/// @notice Deploys MockYieldVault, then mines CREATE2 salt for
///         ILAwareLimitOrderHook and deploys the hook.
///
/// Usage (Unichain Testnet):
///   source .env
///   forge script script/DeployHookathon.s.sol:DeployHookathon \
///     --rpc-url $UNICHAIN_TESTNET_RPC_URL \
///     --broadcast --verify -vvvv
///
/// Usage (Unichain Mainnet):
///   forge script script/DeployHookathon.s.sol:DeployHookathon \
///     --rpc-url https://mainnet.unichain.org \
///     --broadcast --verify -vvvv
///
/// Required .env vars:
///   DEPLOYER_PRIVATE_KEY — deployer EOA private key
///   VAULT_ASSET          — ERC-20 token address the vault accepts
///                          (set to WETH or USDC depending on pool)
contract DeployHookathon is Script {
    // ── Unichain Addresses ───────────────────────────────────
    /// @dev Unichain Mainnet PoolManager (same address on testnet)
    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);

    // ── Hook Permission Flags (7 flags, total = 0x14CE) ──────
    //   AFTER_INITIALIZE_FLAG              = 1 << 12 = 0x1000
    //   AFTER_ADD_LIQUIDITY_FLAG           = 1 << 10 = 0x0400
    //   BEFORE_SWAP_FLAG                   = 1 << 7  = 0x0080
    //   AFTER_SWAP_FLAG                    = 1 << 6  = 0x0040
    //   BEFORE_SWAP_RETURNS_DELTA_FLAG     = 1 << 3  = 0x0008
    //   AFTER_SWAP_RETURNS_DELTA_FLAG      = 1 << 2  = 0x0004
    //   AFTER_ADD_LIQUIDITY_RETURNS_DELTA  = 1 << 1  = 0x0002
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address vaultAsset = vm.envAddress("VAULT_ASSET");

        console2.log("=== ILAwareLimitOrderHook - UHI9 Hookathon Deploy ===");
        console2.log("Deployer:     ", deployer);
        console2.log("PoolManager:  ", address(POOL_MANAGER));
        console2.log("Vault asset:  ", vaultAsset);
        console2.log("Hook flags:   ", FLAGS);

        // ── Step 1: Deploy MockYieldVault ─────────────────────
        vm.startBroadcast(deployerPk);
        MockYieldVault vault = new MockYieldVault(vaultAsset);
        vm.stopBroadcast();

        console2.log("\n[1] MockYieldVault deployed at:", address(vault));

        // ── Step 2: Mine CREATE2 salt for hook address ────────
        //    HookMiner runs in simulation (pure library) — no broadcast needed.
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, deployer, address(vault));

        console2.log("\n[2] Mining CREATE2 salt for hook address...");
        console2.log("    Required flags (low 14 bits of address): 0x%x", FLAGS);

        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(deployer, FLAGS, type(ILAwareLimitOrderHook).creationCode, constructorArgs);

        console2.log("    Salt found:    ", vm.toString(salt));
        console2.log("    Expected hook: ", expectedHookAddress);

        // Sanity check: low 14 bits must match FLAGS
        uint160 addrFlags = uint160(expectedHookAddress) & 0x3FFF;
        require(addrFlags == FLAGS, "DeployHookathon: mined address flags mismatch");

        // ── Step 3: Deploy hook via CREATE2 ───────────────────
        vm.startBroadcast(deployerPk);
        ILAwareLimitOrderHook hook =
            new ILAwareLimitOrderHook{salt: salt}(POOL_MANAGER, deployer, address(vault));
        vm.stopBroadcast();

        require(address(hook) == expectedHookAddress, "DeployHookathon: deployed address mismatch");

        // ── Summary ───────────────────────────────────────────
        console2.log("\n========================================");
        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("========================================");
        console2.log("MockYieldVault: ", address(vault));
        console2.log("Hook address:   ", address(hook));
        console2.log("Hook owner:     ", hook.owner());
        console2.log("yieldVault:     ", hook.yieldVault());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Initialize a pool with this hook via PoolManager.initialize()");
        console2.log("  2. Update frontend/src/config/contracts.ts with hook address");
        console2.log("  3. Add liquidity using script/AddLiquidityUnichain.s.sol");
    }
}
