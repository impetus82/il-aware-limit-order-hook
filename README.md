# ILAwareLimitOrderHook

> **IL-Aware Limit Orders with Auto-Yield** — a Uniswap V4 hook that turns every limit order into a yield-bearing DeFi position, and compensates LPs for impermanent loss from the yield earned.

Submitted to the **[UHI9 — Uniswap Hookathon](https://atrium.academy/uniswap)** · Deployed on **Unichain**

---

> **Demo Video (≤5 min):** [Watch on YouTube ↗](https://youtu.be/eikjiI5kq8I)
>
> **Live Frontend:** [il-aware-hook.vercel.app](https://il-aware-hook.vercel.app) (Unichain mainnet)

---

## Development Timeline

- **April 2026:** LimitOrderHook v2 deployed on Base + Unichain mainnet
  (prior work, separate repo: [github.com/impetus82/limit-order-hook-v4](https://github.com/impetus82/limit-order-hook-v4))
- **May 17–19, 2026:** ILAwareLimitOrderHook scaffolded as Hookathon
  preparation (pre-competition architecture work — IL rebate engine,
  SimulatedYieldVault, 46-test suite, Unichain mainnet deploy)
- **May 25 – June 11, 2026:** Active Hookathon development period
  (SimulatedYieldVault refinement, testing, demo, final submission)

---

## Partner Integrations

No partner integrations. This project targets the Uniswap **Impermanent Loss & Yield Systems** theme directly, built on Uniswap V4 + OpenZeppelin primitives only (no third-party sponsor technology).

---

## What It Does

Traditional limit orders on-chain are capital-idle: your tokens sit in a contract earning nothing while you wait for the price to hit your target.

**ILAwareLimitOrderHook** changes this:

1. **Place a limit order** — tokens are held in the hook
2. **Order executes automatically** when a swap moves the pool price through your trigger level
3. **Deposit output to a yield vault** (ERC-4626) — output tokens start earning yield immediately
4. **Claim with IL rebate** — when you withdraw, the hook calculates how much impermanent loss your position suffered and rebates it from the accumulated yield

The result: you never leave money on the table. Every pending order earns yield, and executed orders get partial IL compensation — all without any external oracle.

---

## Architecture

```
User                PoolManager              ILAwareLimitOrderHook
 |                      |                            |
 |-- createLimitOrder() ------------------------------>  mint ERC-721 NFT
 |                      |                            |  register trigger tick
 |                      |                            |
 |-- swap() ------------>|                            |
 |                      |-- afterSwap() ------------->  walk linked list
 |                      |                            |  execute eligible orders
 |                      |                            |  output held in hook
 |                      |                            |
 |-- depositToVault() -------------------------------->  ERC-4626 deposit
 |                      |                            |  shares recorded in order
 |                      |                            |
 |-- claimOrder() ------------------------------------->  redeem vault shares
 |                      |                            |  calculate IL rebate
 |                      |                            |  rebate = min(yield, IL)
 |                      |                            |  burn ERC-721 NFT
 |<------ output + rebate ---------------------------|
```

---

## Key Technical Features

### 1. O(1) Tick Scan via Doubly-Linked List

Instead of scanning a fixed range of ticks on every swap (O(n) regardless of population), the hook maintains a **sorted doubly-linked list of only active ticks** — ticks that actually contain orders.

```
SENTINEL_MIN <-> tick(-500) <-> tick(0) <-> tick(300) <-> SENTINEL_MAX
```

- **O(1) insertion** at the correct sorted position
- **O(1) removal** when a tick's last order is filled or cancelled
- **O(K) scan** per swap where K = number of populated ticks crossed, not total tick range

This means a 10,000-tick price move costs the same as a 1-tick move if there are only 2 active ticks between them.

### 2. Flash Accounting Integration

All token flows use Uniswap V4's native flash accounting (`sync -> transfer -> settle -> take`), ensuring:
- No ERC-20 `transferFrom` overhead during order execution
- Atomic settlement within the PoolManager's unlock context
- Compatibility with V4's transient storage model (Cancun EVM)

### 3. Anti-DoS Graceful Execution + Hard Price Gate

`_executeOrder` returns `bool success` instead of reverting — a single toxic order can never revert a
third party's triggering swap:

```solidity
// A skipped order emits an event and stays resting; the swap still completes.
if (!success) {
    emit OrderExecutionFailed(orderId, "PriceGate");
    i++; // don't revert the whole swap; try again next swap
}
```

Fills are protected by a **hard price gate** (fix M4): the internal fill swap's `sqrtPriceLimitX96` is
anchored to the order's own `triggerPrice ± MAX_SLIPPAGE_BPS` (0.5%) via the non-reverting
`_tolerantSqrtLimit`, so the swap is *physically unable* to execute worse than the user's price — it is
not a post-hoc "fill anyway and warn" check. An order that cannot fill within tolerance skips cleanly
(a provably zero-delta no-op); an order larger than the tolerance-band depth fills **partially at
trigger-or-better** and refunds the unused input (the order then closes; the remainder is not re-queued).

Gas metering prevents out-of-gas reverts when many orders queue up:
```solidity
if (gasleft() < GAS_LIMIT_PER_ORDER) break; // resume next swap
```

Together these eliminate the DoS vector present in naive limit-order hook designs *and* the "limit order
fills below your price" flaw of an advisory slippage check.

### 4. Oracle-Free IL Calculation

IL is estimated purely from `sqrtPriceX96` delta — no Chainlink, no TWAP oracle needed:

```
sqrtR  = sqrtPriceCurrent * 1e9 / sqrtPriceEntry
diff   = |sqrtR - 1e9|
IL  ~  size * diff^2 / (2 * 1e9^2)        // size = the order's own output amount
```

This is a second-order Taylor approximation of the constant-product IL formula — no external feed, only the `sqrtPriceX96` snapshots the hook already records (`sqrtPriceBaseline` at pool init, `sqrtPriceAtFill` on execution). The multiplier is the order's own output `size`, so `ilAmount` is a conservative rebate-sizing figure rather than a pool-wide LP-IL number — which is all it needs to be, since the rebate is hard-capped at the yield actually earned.

### 5. ERC-721 Composability

Every limit order is minted as an **ERC-721 NFT** at creation time (`orderId == tokenId`). This enables:
- **Secondary market trading** of pending orders (sell a 2000 USDC/WETH buy order at a discount if you need liquidity now)
- **Access control without `creator` storage** — `ownerOf(orderId)` is always the canonical authority
- **Graceful cleanup** — `_ownerOf(orderId) == address(0)` detects burned (cancelled/claimed) orders without iterating

---

## Who Bears the IL Risk?

**Short answer: nobody is made worse off.**

When a limit order executes in a pool, the executing swap moves the price — that price impact is IL for existing LPs. The order creator also participates in this IL because their output tokens were worth more at the pre-swap price.

This hook addresses that loss with a two-sided mitigation:

| Actor | Without This Hook | With This Hook |
|-------|-------------------|----------------|
| Order creator | Receives output tokens, no yield while waiting | Output earns yield in ERC-4626 vault |
| Order creator after fill | Receives exactly `amountOut`, no IL recovery | Receives `amountOut + min(yield, IL)` |
| LP providing liquidity | Earns fees, suffers full IL from limit executions | Unchanged — the hook takes no LP funds (the spoofable `lpPositions` telemetry was **removed**, finding J1) |

The rebate formula `rebate = min(yield, ilAmount)` ensures:
- The creator can never receive **more** than their actual IL (no windfall)
- If `yield >= IL`: creator is fully compensated, keeps any excess yield
- If `yield < IL`: creator keeps all yield and absorbs only the residual IL — net-positive versus an idle order whenever yield exceeds the small execution fee

**Solvency is preserved by construction.** The rebate is capped at `min(yield, ilAmount)` *and*, in the
vault path, hard-capped at the amount the vault actually redeemed in the same transaction (the M2
`RebateExceedsRedeemed` guard) — so the payout is self-funded by construction, and a future change to the
IL formula can never silently draw from other orders' custody or from fees. Every order is isolated by
`orderId` (no shared pot to drain). If the vault ever reverts on redeem, `claimOrder` degrades
gracefully: it draws nothing from other orders' custody, leaves the position fully intact (NFT + vault
shares), emits `VaultRedeemFailed`, and lets the owner re-claim once the vault recovers — so a vault
failure can neither make the hook insolvent nor trap a user's funds. These properties are checked under
random sequences by the Phase-2 [invariant suite](#security--audit).

> **Finding J1 — resolved.** An earlier `lpPositions` map recorded LP identities from unauthenticated
> `hookData` (spoofable, and never read for any payout, rebate, eligibility, or access-control path). It
> has been **removed** along with `getLPPosition`; `afterAddLiquidity` is now a no-op. The permission
> flag is retained only so the deployed hook address stays valid.

---

## Hook Permissions

All 7 flags are enabled:

| Flag | Bit | Purpose |
|------|-----|---------|
| `afterInitialize` | 12 | Record `lastTick` and `sqrtPriceBaseline` at pool creation |
| `afterAddLiquidity` | 10 | No-op (flag retained; the spoofable LP telemetry it once recorded was removed — J1) |
| `beforeSwap` | 7 | Passthrough (required for `beforeSwapReturnDelta`) |
| `afterSwap` | 6 | Execute eligible orders, update `lastTick` |
| `beforeSwapReturnDelta` | 3 | Reserved for a future dynamic-fee pathway |
| `afterSwapReturnDelta` | 2 | Enable precise output accounting |
| `afterAddLiquidityReturnDelta` | 1 | Reserved — currently returns a zero delta (no-op) |

---

## Contract Interface

```solidity
// Place a limit order -- mints ERC-721 NFT to msg.sender.
// NOTE the parameter order: (poolKey, zeroForOne, amountIn, triggerPrice).
function createLimitOrder(
    PoolKey calldata poolKey,
    bool zeroForOne,      // sell token0 (true) or buy token0 (false)
    uint96 amountIn,      // input amount escrowed
    uint128 triggerPrice  // 1e18-scaled; must be in (0, MAX_TRIGGER_PRICE = 1e36]
) external returns (uint256 orderId);

// Cancel active order -- burns NFT, refunds input tokens (owner only)
function cancelOrder(uint256 orderId) external;

// After order fills: deposit output to the ERC-4626 vault to earn yield (owner only).
// Only works if the order's OUTPUT token is the vault asset; otherwise it no-ops gracefully.
function depositToVault(uint256 orderId) external;

// Claim filled order output + optional IL rebate from yield; burns the NFT (owner only).
// The full PoolKey is REQUIRED and validated (reverts PoolKeyMismatch on a foreign key).
function claimOrder(uint256 orderId, PoolKey calldata poolKey) external;

// Admin (Ownable): execution-fee controls and stuck-order cleanup.
function setFeeBps(uint256 newFeeBps) external;              // <= MAX_FEE_BPS = 50 (0.5%)
function withdrawFees(Currency currency, address recipient) external; // pendingFees only
function forceCancelOrder(uint256 orderId) external;         // UNFILLED orders only
```

> **Protocol revenue (`pendingFees`).** Each fill skims `feeBps` (default **5 BPS = 0.05%**,
> admin-settable up to 0.5%) from the output into `pendingFees`. On claim, any vault yield beyond the
> `min(yield, IL)` rebate is likewise captured into `pendingFees` (rather than left stranded in the hook).
> Both are withdrawable by the owner via `withdrawFees` and are held in a balance structurally separate
> from order custody — each credited only after the matching physical `take`/`redeem`
> (see [Security](#security--audit)).

### Integrating programmatically (SDK)

A typed, framework-agnostic **viem SDK** lives in [`sdk/`](sdk/) and wraps the integration footguns:
trigger-price encoding (6-decimals direct on Base vs 30-decimals inverted on Unichain), `zeroForOne`
direction per chain's token sort, the required `PoolKey` tuple in `claimOrder`, uint96 bounds, and
typed readers with order-status derivation. Start with
**[docs/INTEGRATION.md](docs/INTEGRATION.md)** — deployments table, order lifecycle, quickstart,
raw-call reference, and event signatures. The SDK's chain config is locked to the live pools by test:
`keccak256(abi.encode(poolKey))` must reproduce both on-chain poolIds.

---

## Security & Audit

This contract has been hardened for an external audit. Two auditor-facing documents accompany it:

- **[docs/AUDIT_SCOPE.md](docs/AUDIT_SCOPE.md)** — contracts in/out of scope, actors & trust model
  (exact admin powers and limits), external dependencies, assets at risk, and accepted risks.
- **[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)** — attack surface per entry point, the core security
  properties and why they hold, and a table of concrete attack scenarios with mitigations.

### Findings addressed

Every finding from the hackathon judge feedback and an independent audit-prep scan is fixed on branch
`fix/pool-isolation-h1-h2` (one commit per finding):

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| **H1** | HIGH | `claimOrder` accepted a caller-chosen `PoolKey` (no order→pool binding) | Order stores `poolId`; `claimOrder` reverts `PoolKeyMismatch` on a foreign key |
| **H2** | HIGH | Tick buckets / active-tick list not namespaced by `PoolId` → cross-pool collision | All order indexing namespaced by `PoolId`; per-pool sentinels; unsound `token0` filter removed |
| **H3** | HIGH | `forceCancelOrder` could strand `vaultShares` | Proven unreachable (`vaultShares>0 ⟹ isFilled`); documented invariant + test |
| **M1** | MED | IL used output amount as a dimensionally-wrong "liquidity" | Renamed `outputNotional` + honest NatSpec; safety is the yield cap, not precision |
| **M2** | MED | `pendingFees` + order outputs shared one balance | Structural guard: vault-path payout reverts `RebateExceedsRedeemed` if it exceeds redeemed; solvency tests |
| **M3** | MED | Unbounded per-tick arrays → O(n) cancel/forceCancel griefing DoS | O(1) swap-and-pop via `orderBucketIndex` |
| **M4** | MED | Fixed ±5% advisory slippage → orders could fill worse than trigger | Hard price gate anchored to `triggerPrice` (± 0.5%); skip-and-rest; forced-fill blocks deleted |
| **J1** | LOW | LP identity via `hookData` is spoofable | **Removed** the dead `lpPositions` / `getLPPosition` telemetry; `afterAddLiquidity` is now a no-op (flag kept to preserve the deployed hook address) |
| **J2** | LOW | IL uses spot price, no TWAP | Accepted — `min(yield, IL)` + `redeemed` caps bound it to the user's own yield; documented |
| **L1** | LOW | Extreme `triggerPrice` could panic / defeat the M4 gate | `MAX_TRIGGER_PRICE = 1e36` bound (clean revert before any state change) |

**Static analysis:** Slither 0.11.5 was run over the contract; all findings were triaged as
false-positives or intentional patterns (mappings reported "uninitialized" but populated by index;
deliberate divide-before-multiply in the fixed-point price/tick math; benign reentrancy already guarded
by `nonReentrant` + the `isExecuting` flag; intentional `address(0)` = no-vault mode). No real issue was
found. Full triage in [docs/AUDIT_SCOPE.md](docs/AUDIT_SCOPE.md).

### Invariants (Phase-2 Foundry suite)

`test/ILAwareLimitOrderHookInvariant.t.sol` drives random sequences over **two pools sharing
`currency0`** (the H1/H2 collision shape), in a no-vault and a yielding-vault configuration, asserting
after every action:

1. **Solvency** — `balanceOf(hook) >= custody(unfilled) + output(filled-unclaimed) + pendingFees`
   per currency (vault-deposited output excluded; `pendingFees` now captures the un-rebated yield on
   claim, so `>=` remains only for sub-wei ERC-4626 redemption-rounding dust).
2. **Pool isolation & bucket hygiene** — every bucket entry belongs to its pool, is live + unfilled,
   and unique.
3. **Vault-share consistency** — `Σ order.vaultShares == vault.sharesOf(hook)`.

The suite also drives a vault that can **revert** or **haircut** redeems and orders large enough to
force **partial fills** — the invariants hold under all of these, and each was mutation-tested (shown to
fail on an injected bug), so the suite has teeth.

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies
forge install

# Set environment variables
export DEPLOYER_PRIVATE_KEY=0x...
export VAULT_ASSET=0x4200000000000000000000000000000000000006  # WETH on Unichain
```

### Deploy to Unichain

```bash
# Unichain Mainnet
forge script script/DeployHookathon.s.sol:DeployHookathon \
  --rpc-url https://mainnet.unichain.org \
  --broadcast --verify -vvvv

# Unichain Testnet
forge script script/DeployHookathon.s.sol:DeployHookathon \
  --rpc-url $UNICHAIN_TESTNET_RPC_URL \
  --broadcast --verify -vvvv
```

The script automatically:
1. Deploys `SimulatedYieldVault` (ERC-4626 compatible, 3% APY via `block.timestamp`)
2. Mines the CREATE2 salt via `HookMiner` to satisfy all 7 permission flags
3. Deploys `ILAwareLimitOrderHook` at the mined address

### Deploy to Base — real Aave yield

Aave is not deployed on Unichain, so the Unichain deployment uses the simulated vault. On **Base**, the
hook can point directly at the real Aave USDC Static aToken (**waBasUSDC**, an ERC-4626 `StataTokenV2`,
`asset() == USDC`) — making the auto-yield rebate real. The hook is vault-agnostic (immutable `yieldVault`,
ERC-4626 only), so this is a fresh deploy, not a code change. The lifecycle is proven end-to-end against
real Base Aave in `test/ILAwareLimitOrderHookAaveFork.t.sol` (run with `RUN_FORK_TESTS=1`).

```bash
cp .env.example .env    # then set DEPLOYER_PRIVATE_KEY (YIELD_VAULT/POOL_MANAGER default to Base)

# 1) DRY RUN first (no --broadcast): forks Base, checks waBasUSDC.asset() == USDC, mines the salt
forge script script/DeployBaseAave.s.sol:DeployBaseAave --rpc-url https://mainnet.base.org -vvvv

# 2) Broadcast + verify once the simulation looks right
forge script script/DeployBaseAave.s.sol:DeployBaseAave \
  --rpc-url https://mainnet.base.org --broadcast --verify -vvvv
```

`DeployBaseAave` deploys **no** demo vault; it wires `yieldVault = waBasUSDC` and runs pre-flight ERC-4626
sanity checks before broadcasting. On Base `WETH < USDC`, so a WETH/USDC pool has `currency0 = WETH`
(opposite Unichain) and the vault path routes only USDC-output orders.

### Deployed Addresses

| Network | Contract | Address |
|---------|----------|---------|
| Unichain Mainnet | ILAwareLimitOrderHook | [0x3983130fcd18606afe659acdddb0018d21c254ce](https://uniscan.xyz/address/0x3983130fcd18606afe659acdddb0018d21c254ce) |
| Unichain Mainnet | SimulatedYieldVault | [0xad5e352E96B972BE0ae1eDd2d1f60E69bf1Ee608](https://uniscan.xyz/address/0xad5e352e96b972be0ae1edd2d1f60e69bf1ee608) |
| Unichain Mainnet | USDC/WETH Pool | PoolId: `0x093ab4b09860ac96a823165918b56e35837631d16440daa15385b3f0d7b23279` |
| Base Mainnet | ILAwareLimitOrderHook (**real Aave vault**) | [0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce](https://basescan.org/address/0x4fb56294f7bff30a4d85c1ba676f0cfdb24114ce) |
| Base Mainnet | waBasUSDC vault (Aave USDC Static aToken, ERC-4626) | [0xC768c589647798a6EE01A91FdE98EF2ed046DBD6](https://basescan.org/address/0xc768c589647798a6ee01a91fde98ef2ed046dbd6) |
| Base Mainnet | WETH/USDC Pool | PoolId: `0xc92fdde3c2264c8abe30cea3ee4d3ffeeef6ca009117e843158f8f8a5fe6f03e` |

Unichain redeploy (hook) tx: [0x9b8727243389d53291029454f5058e7563888de1224b78a1af372d24bfcee8a4](https://uniscan.xyz/tx/0x9b8727243389d53291029454f5058e7563888de1224b78a1af372d24bfcee8a4) — Uniscan-verified. Seed held by the recoverable `LiquidityRouterUnichain` at `0x17d2458D25D3254844EeC70457860CDEEdeAf258`.

Base deploy tx: [0x93d1f1230f2dffc494b961fa189a47b8b5cdfad6f43130d967ed264909b61eba](https://basescan.org/tx/0x93d1f1230f2dffc494b961fa189a47b8b5cdfad6f43130d967ed264909b61eba) — Basescan-verified, funded by **real Aave USDC yield**; the WETH/USDC pool (`currency0 = WETH`) is live and seeded. This 2026-08-08 redeploy carries the internal-audit fixes (A1/A2 afterSwap DoS, A3 reentrancy gate, A4 measured-receipt); it supersedes `0x1afe…94Ce`.

> **Operational note.** The Base pool's seed liquidity is held by the `LiquidityRouterBase` deployed at
> [`0x43C9503c43F987Ca0AF2E2ea4425db08f435eAD8`](https://basescan.org/address/0x43c9503c43f987ca0af2e2ea4425db08f435ead8)
> (owner = deployer). Deepen the pool with another `addLiquidity`, or withdraw the seed with
> `removeLiquidity(poolKey, deployed())` — the v4 position belongs to that router, so this address is
> the only way to reach it.

---

## Testing

```bash
# Run all 70 tests
forge test -vvv

# Unit tests (pure functions, no deployment)
forge test --match-contract ILAwareLimitOrderHookTest -vvv

# Integration tests (full PoolManager + hook lifecycle)
forge test --match-contract ILAwareLimitOrderHookIntegrationTest -vvv

# Phase-2 invariant suite (solvency / pool-isolation / vault-share consistency)
forge test --match-path test/ILAwareLimitOrderHookInvariant.t.sol -vvv

# Gas report
forge test --gas-report
```

**Test coverage:** 70 tests — 70 passing, 0 failing (63 unit/integration + 7 Phase-2 invariants).

Key scenarios covered:
- `test_AfterInitialize` — baseline price recorded at pool creation
- `test_ILCalculation_PriceDoubled` — IL approximation accuracy
- `test_YieldRebate_OnClaim` — end-to-end vault yield rebate flow
- `test_ERC721_Claim_After_Transfer` — secondary market: new NFT owner claims filled order
- `testGracefulExecutionOnSlippage` — anti-DoS: a failed order does not block the pool
- `test_GracefulClaim_VaultReverts_JuneFix` — vault redeem failure never traps funds; position preserved and re-claimable
- `test_H2_CrossPoolIsolation` — an order in pool A is never filled by a swap in a different pool sharing `currency0`
- `test_M4_HardGate_PartialFillProtectsPrice` — a large order fills partially at trigger-or-better and refunds the rest
- `test_L1_RejectsExcessiveTriggerPrice` — an out-of-range trigger price reverts cleanly instead of panicking
- `invariant_solvency` / `invariant_poolIsolationAndBucketHygiene` / `invariant_vaultSharesConsistent` — Phase-2 invariants over two pools sharing `currency0`, with a vault that can revert/haircut redeems and force partial fills

---

## Project Structure

```
.
|-- src/
|   |-- ILAwareLimitOrderHook.sol       # Main hook contract
|-- script/
|   |-- DeployHookathon.s.sol           # One-shot Unichain deployment (demo SimulatedYieldVault)
|   |-- DeployBaseAave.s.sol            # Base production deploy — real Aave vault (waBasUSDC)
|   |-- HookMiner.sol                   # CREATE2 salt miner
|   |-- AddLiquidityUnichain.s.sol
|   |-- TriggerSwapUnichain.s.sol
|   +-- RecoverPool.s.sol
|-- test/
|   |-- ILAwareLimitOrderHook.t.sol              # Unit tests (5 tests)
|   |-- ILAwareLimitOrderHookIntegration.t.sol   # Integration tests (58 tests)
|   |-- ILAwareLimitOrderHookInvariant.t.sol     # Phase-2 Foundry invariants (solvency / isolation / vault shares)
|   +-- ILAwareLimitOrderHookAaveFork.t.sol       # Real Aave (Base) fork test — RUN_FORK_TESTS=1
|-- docs/
|   |-- AUDIT_SCOPE.md                           # Audit scope, actors, assets at risk, accepted risks
|   |-- THREAT_MODEL.md                          # Attack surface, security properties, attack scenarios
|   +-- INTEGRATION.md                           # Integrator guide: deployments, lifecycle, quickstart
|-- sdk/                                         # Typed viem SDK (addresses, price encoding, tx builders)
|   |-- src/                                     # abi / addresses / price / orders
|   +-- test/                                    # 18 vitest tests (incl. poolId keccak cross-check)
+-- frontend/                                    # Next.js 16 + wagmi v2
    +-- src/
        |-- components/
        |   |-- OrderList.tsx       # ERC-721 order UI with vault actions
        |   +-- CreateOrderForm.tsx
        +-- config/
            |-- abi.json            # Auto-generated by forge build
            +-- contracts.ts        # Chain addresses, poolKey helpers
```

---

## Tech Stack

- **Uniswap V4** — PoolManager, BaseHook, flash accounting
- **Solidity 0.8.26** — via-IR optimizer, Cancun EVM (transient storage)
- **OpenZeppelin** — ERC-721, ERC-4626 (IERC4626), ReentrancyGuard, SafeERC20
- **Foundry** — forge build / test / script
- **Next.js 16** + **wagmi v2** + **viem** + **RainbowKit** — frontend

---

## License

MIT

---

Built for **UHI9 Uniswap Hookathon** · May 2026
