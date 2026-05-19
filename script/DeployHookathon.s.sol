// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILAwareLimitOrderHook} from "../src/ILAwareLimitOrderHook.sol";
import {HookMiner} from "./HookMiner.sol";

// ============================================================
//  SIMULATED YIELD VAULT (Hookathon Demo Day)
// ============================================================

/// @title  SimulatedYieldVault
/// @notice ERC-4626 compatible vault that simulates time-based APY accumulation.
///
///         Motivation: Aave / Morpho are not yet deployed on Unichain Mainnet at
///         Hookathon time, so real yield is unavailable. This vault produces
///         deterministic, auditable yield for Demo Day using block.timestamp.
///
/// Yield formula (simple interest, accrues since vault deployment):
///
///   assets = shares + shares * APY_BPS * elapsed / (10_000 * 365 days)
///
/// Where:
///   APY_BPS = 300  (3% per year)
///   elapsed = block.timestamp - startTime
///
/// Mint-on-demand for tests:
///   If the vault's token balance is insufficient to cover the simulated yield,
///   it attempts a low-level `mint(address,uint256)` call on the asset contract
///   (succeeds in test environments with MockERC20; no-op with real WETH).
///   In production, the vault owner should top up with extra WETH to fund yield.
contract SimulatedYieldVault {
    IERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    /// @dev 3% APY expressed in basis points
    uint256 public constant APY_BPS = 300;
    /// @dev Timestamp at vault deployment; yield accrues from this point
    uint256 public immutable startTime;

    constructor(address _asset) {
        asset = IERC20(_asset);
        startTime = block.timestamp;
    }

    // ── Core ERC-4626: deposit / redeem ─────────────────────────────────────

    /// @notice Deposit `assets`, receive 1:1 shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        sharesOf[receiver] += shares;
        totalShares += shares;
    }

    /// @notice Redeem `shares` for principal + simulated APY yield
    /// @dev In test environments the yield deficit is minted; in production it
    ///      is capped to the vault's actual WETH balance.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(sharesOf[owner] >= shares, "SimulatedYieldVault: insufficient shares");
        sharesOf[owner] -= shares;
        totalShares -= shares;

        uint256 simulated = previewRedeem(shares);
        uint256 balance = asset.balanceOf(address(this));

        if (simulated > balance) {
            // Attempt to mint yield deficit (works with MockERC20 in test environments)
            uint256 deficit = simulated - balance;
            (bool ok,) = address(asset).call(
                abi.encodeWithSignature("mint(address,uint256)", address(this), deficit)
            );
            assets = ok ? simulated : balance; // graceful fallback in production
        } else {
            assets = simulated;
        }
        asset.transfer(receiver, assets);
    }

    // ── ERC-4626: preview / view ─────────────────────────────────────────────

    /// @notice Principal + simple-interest APY since vault deployment
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        uint256 yieldAmt = (shares * APY_BPS * elapsed) / (10_000 * 365 days);
        return shares + yieldAmt;
    }

    function totalAssets() external view returns (uint256) {
        return previewRedeem(totalShares);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return previewRedeem(shares);
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1 entry ratio
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256 shares) {
        uint256 elapsed = block.timestamp - startTime;
        uint256 denom = 10_000 * 365 days + APY_BPS * elapsed;
        shares = (assets * (10_000 * 365 days)) / denom;
    }

    function maxDeposit(address) external pure returns (uint256) { return type(uint256).max; }
    function maxMint(address) external pure returns (uint256)    { return type(uint256).max; }
    function maxRedeem(address owner) external view returns (uint256) { return sharesOf[owner]; }
    function maxWithdraw(address owner) external view returns (uint256) {
        return previewRedeem(sharesOf[owner]);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = shares;
        asset.transferFrom(msg.sender, address(this), assets);
        sharesOf[receiver] += shares;
        totalShares += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets;
        require(sharesOf[owner] >= shares, "SimulatedYieldVault: insufficient shares");
        sharesOf[owner] -= shares;
        totalShares -= shares;
        asset.transfer(receiver, assets);
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

    /// @dev Standard deterministic CREATE2 factory (EIP-2470 / Nick's factory).
    ///      Foundry routes `new Contract{salt:}()` through this address during broadcast.
    ///      Must be used as the `deployer` argument to HookMiner.find() so the
    ///      mined address matches what will actually be deployed on-chain.
    address constant HOOK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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

        // ── Step 1: Deploy SimulatedYieldVault ───────────────
        vm.startBroadcast(deployerPk);
        SimulatedYieldVault vault = new SimulatedYieldVault(vaultAsset);
        vm.stopBroadcast();

        console2.log("\n[1] SimulatedYieldVault deployed at:", address(vault));
        console2.log("     APY_BPS:", vault.APY_BPS(), "(3% per year)");
        console2.log("     startTime:", vault.startTime());

        // ── Step 2: Mine CREATE2 salt for hook address ────────
        //    HookMiner runs in simulation (pure library) — no broadcast needed.
        //    IMPORTANT: use HOOK_CREATE2_FACTORY (not the EOA) as the deployer, because
        //    Foundry routes `new Contract{salt:}()` through the deterministic factory.
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, deployer, address(vault));

        console2.log("\n[2] Mining CREATE2 salt for hook address...");
        console2.log("    Required flags (low 14 bits of address): 0x%x", FLAGS);
        console2.log("    CREATE2 factory: ", HOOK_CREATE2_FACTORY);

        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(HOOK_CREATE2_FACTORY, FLAGS, type(ILAwareLimitOrderHook).creationCode, constructorArgs);

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
        console2.log("SimulatedYieldVault:", address(vault));
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
