# ILAwareLimitOrderHook — Audit Scope

**Prepared for:** external audit firm
**Contact:** egoshin_crypto@proton.me
**Repository state:** branch `fix/pool-isolation-h1-h2`, all findings (H1–M4, J1, J2) + L1 fixed, 70 tests passing.
**Compiler:** Solidity `0.8.26`, `via-IR`, EVM `cancun`, optimizer on (`runs = 200`).

---

## 1. Overview

`ILAwareLimitOrderHook` is a Uniswap V4 hook that lets users place **on-chain limit orders** against a
V4 pool. A creator deposits an input token; the order rests in a per-pool, tick-indexed data structure
and is filled automatically inside the hook's `afterSwap` callback once a third party's swap pushes the
pool price past the order's `triggerPrice`. Fills are executed via an internal `PoolManager.swap` that
is hard-gated to the trigger price (± 0.5%), so an order can never fill worse than its trigger within
tolerance. Each order is tokenized as an **ERC-721 position** (the tokenId equals the orderId), so
ownership — and therefore the right to cancel or claim — travels with the NFT. Filled output is
custodied by the hook and released by an explicit `claimOrder`, which may optionally add a small
**IL-rebate** funded strictly from yield the position earned in an attached ERC-4626 vault. A
configurable execution fee (≤ 0.5%) is skimmed from each fill and accrues to the hook owner.

---

## 2. Contracts IN SCOPE

| File | Notes |
|------|-------|
| `src/ILAwareLimitOrderHook.sol` | **The only contract in scope.** ~1200 LOC. Inherits `BaseHook` (v4-periphery), `ReentrancyGuard`, `Ownable`, `ERC721` (OpenZeppelin). Contains all order lifecycle, tick-list, execution, fee, and IL-rebate logic. |

The `yieldVault` is chain-dependent: the **Unichain** deployment points at the demo `SimulatedYieldVault`,
while the **Base** production deployment points at the REAL Aave USDC Static aToken (**waBasUSDC**, ERC-4626).
Either way the vault is an EXTERNAL dependency, **OUT OF SCOPE** for this audit (see §3) — the hook is
vault-agnostic and treats *any* `yieldVault` as a trusted-ish external ERC-4626 (see §5). `SimulatedYieldVault`
is defined only in `script/` and tests, never in `src/`. Audit effort should focus on the hook's assumptions
about the vault (deposit / redeem, no reentrancy, lossy or failed redeem), not any specific vault's internals.

---

## 3. OUT OF SCOPE

- **Frontend** (`frontend/**`) — Next.js / wagmi UI. Note: the README currently documents a **wrong
  parameter order** for `createLimitOrder`; the authoritative signature is in §4.
- **Scripts** (`script/**`) — deploy / liquidity / trigger helpers. These contain known unsafe casts and
  unchecked ERC-20 transfers; they are deploy-time tooling, not the audited hook.
- **`SimulatedYieldVault`** — demo ERC-4626 vault (simulated 3% APY from `block.timestamp`). Not a real
  lending venue. Trusted as an external dependency by the in-scope contract.
- **Uniswap v4-core / v4-periphery** (`PoolManager`, `BaseHook`, `TickMath`, `StateLibrary`, etc.).
- **OpenZeppelin contracts** (`ERC721`, `Ownable`, `ReentrancyGuard`, `SafeERC20`, `SafeCast`, `IERC4626`).
- **Tests** (`test/**`) — provided for reference and to communicate intended invariants (§7).

---

## 4. System actors & trust model

### 4.1 Authoritative external interface

```solidity
function createLimitOrder(PoolKey poolKey, bool zeroForOne, uint96 amountIn, uint128 triggerPrice)
    external returns (uint256 orderId);
function cancelOrder(uint256 orderId) external;
function depositToVault(uint256 orderId) external;
function claimOrder(uint256 orderId, PoolKey poolKey) external;   // PoolKey is REQUIRED and validated
```

> `claimOrder` and `createLimitOrder` both take the full `PoolKey` tuple. `claimOrder` reverts
> `PoolKeyMismatch` if the supplied key does not hash to the order's stored `poolId` (fix H1).

### 4.2 Order creator / NFT owner

- Calls `createLimitOrder` (custodies `amountIn` of the input token in the hook).
- **Ownership is the ERC-721 owner, not a stored creator field** — `ownerOf(orderId)`. Transferring the
  NFT transfers the right to `cancelOrder`, `depositToVault`, and `claimOrder`. All three gate on
  `ownerOf(orderId) == msg.sender`.
- Can cancel an **unfilled** order (full refund + NFT burn) or claim a **filled** order (output + optional
  yield rebate, then NFT burn).

### 4.3 Pool swappers (third parties)

- Any swapper on an in-scope pool triggers `afterSwap`, which may fill resting orders.
- A swapper cannot be griefed by a toxic order: failed fills are **skipped gracefully** (emit
  `OrderExecutionFailed`, order stays resting) — a single order can never revert the triggering swap.
- A `gasleft()` budget (`GAS_LIMIT_PER_ORDER = 150_000`) and a `MAX_ACTIVE_TICK_SCAN = 100` bound the
  work any one swap performs.

### 4.4 Liquidity providers (LPs)

- `afterAddLiquidity` is a **no-op** and returns a zero delta. LPs interact with the pool normally; the
  hook takes no LP funds. The earlier spoofable `lpPositions` / `getLPPosition` telemetry (populated from
  unauthenticated `hookData`, never read for any payout or access-control path) has been **removed**
  (finding J1, §8); the permission flag is retained only to keep the deployed hook address valid.

### 4.5 Hook owner / admin (`Ownable`)

The admin's powers are **deliberately narrow**. Enumerated exactly:

| Function | Exact power | Bound |
|----------|-------------|-------|
| `setFeeBps(uint256)` | Set the per-fill execution fee | **Cannot exceed `MAX_FEE_BPS = 50` (0.5%)** — reverts `FeeTooHigh`. Applies to future fills only. |
| `withdrawFees(Currency, address)` | Withdraw accrued protocol revenue | **Can withdraw `pendingFees[currency]` only.** This balance holds the per-fill execution fees *and* the un-rebated vault yield captured on claim (yield beyond the `min(yield, IL)` rebate). Every credit happens *only* after the matching physical `take`/`redeem` into the hook (see M2), so it is structurally disjoint from order custody and vault deposits. |
| `forceCancelOrder(uint256)` | Refund + burn a stuck order | **UNFILLED orders only** — reverts `OrderAlreadyFilled` on a filled order, `OrderNotActive` on an already-burned one. Tokens go to the **current NFT owner**, not the admin. |

**What the admin CANNOT do:**

- **Cannot seize, redirect, or claim a filled order's output.** A filled position is a bearer claim of
  its NFT owner, recoverable only via `claimOrder`. `forceCancelOrder` reverts on any filled order.
- **Cannot strand vault principal.** Because `vaultShares > 0 ⟹ isFilled == true` (monotonic), any
  order with vault deposits is filled and therefore un-force-cancellable (see H3).
- **Cannot touch order principal or output via `withdrawFees`** — `withdrawFees` only ever reads/zeroes
  `pendingFees` and transfers that exact amount.
- **Cannot set a fee above 0.5%.**
- **Cannot pause, upgrade, or change the vault** (`yieldVault` is `immutable`; there is no upgrade path,
  no proxy, no pause switch).
- **Cannot mint order NFTs** or alter ownership (mint happens only inside `createLimitOrder`).

There is **no** `renounceOwnership`/`transferOwnership` restriction beyond stock OpenZeppelin `Ownable`;
auditors should note the usual "owner key compromise" surface is limited to the three powers above.

---

## 5. External dependencies & assumptions

- **Uniswap V4 `PoolManager`** (immutable, set in constructor): trusted. All internal fills go through
  `poolManager.swap` inside the `afterSwap` unlock; `sync`/`settle`/`take` are used for settlement. The
  hook assumes standard V4 semantics (slot0, delta signs, unlock/lock).
- **ERC-4626 vault (`yieldVault`, immutable):** **trusted-ish.** `deposit` is wrapped in
  `try/catch` (deposit failure is a no-op that resets approval and emits `VaultDepositFailed` with the
  raw revert data). `redeem` is wrapped in `try/catch` (redeem failure leaves the position fully intact
  for re-claim, emitting `VaultRedeemFailed`; **no** hook balance is paid on that path). The hook assumes
  the vault does **not** re-enter (it is called from `nonReentrant` functions). It does **not** assume the
  vault reports honestly: the claim payout is priced from `min(reported, measured balance delta)`, so an
  over-reporting vault (or a fee-on-transfer output token) cannot inflate the payout beyond what the hook
  physically received. Likewise `depositToVault` rejects a deposit that consumed assets but credited zero
  shares (`ZeroSharesMinted`) and zeroes the approval on **both** the success and failure paths, so no
  standing allowance survives over the hook's shared balance. A malicious vault can therefore at worst
  grief its own depositors (deposit/redeem DoS) or return a lossy redeem (handled: user is paid exactly
  what arrived); it **cannot** reach other orders' custody — enforced, not merely assumed, by the measured
  receipt plus the `RebateExceedsRedeemed` guard (M2).
- **ERC-20 tokens:** `SafeERC20` used throughout; `ReentrancyGuard` on all token-custody entry points
  (ERC-777 defense). **Decimal assumption:** the IL-rebate math and the `1e18`-scaled price helpers
  (`sqrtPriceToUint128`, `uint128ToSqrtPrice`, `_calculateIL`) implicitly assume ~18-decimal semantics
  in a few places; the live pool's `currency0` is **6-decimal USDC**. This does not threaten solvency
  (the rebate is yield-capped, §9), but it does make the IL *rebate figure* imprecise and is a disclosed
  limitation (see M1/J2 in §9 and the MIN_ORDER_SIZE note).
- **Single-block atomicity:** each fill (internal swap + settle + take) completes atomically within one
  `afterSwap`. `claimOrder`/`depositToVault` are separate transactions; the two-phase design (fill →
  claim) is intentional and relied upon for reentrancy separation from the pool.

---

## 6. Assets at risk

| Asset | Where held | Released by |
|-------|-----------|-------------|
| **Order input (custody)** | Hook balance, tracked in `order.amount0`/`amount1` of unfilled orders | `cancelOrder` / `forceCancelOrder` (refund to owner) or consumed by the fill swap |
| **Filled output** | Hook balance (unless deposited to vault) | `claimOrder` (to NFT owner), optionally + IL rebate |
| **Vault-deposited output** | ERC-4626 vault as shares (`order.vaultShares`) | `claimOrder` redeems shares back into the hook, then pays out |
| **`pendingFees`** | Hook balance, per-currency (execution fees + un-rebated vault yield) | `withdrawFees` (owner only) |
| **Vault shares** | Held by the hook in the vault; each share backed by exactly one live order | tracked by `order.vaultShares`; §7 invariant |

---

## 7. Security properties / invariants to verify

The properties below are asserted by `test/ILAwareLimitOrderHookInvariant.t.sol` (Foundry invariant
suite: `runs = 128`, `depth = 48`, `fail_on_revert = false`). The suite runs one hook across **two pools
sharing `currency0`** — the exact H1/H2 collision shape — in both a no-vault and a yielding-vault
configuration.

1. **Solvency** (`invariant_solvency`): for every currency,
   `balanceOf(hook) >= custody(unfilled orders) + output(filled-unclaimed orders) + pendingFees`.
   Vault-deposited outputs are excluded (backed by the vault, not the hook balance). `pendingFees` now
   captures the un-rebated vault yield on claim (previously left as untracked surplus); `>=` rather than
   `==` remains because ERC-4626 share-redemption rounding can leave sub-wei dust as a safe surplus.
2. **Pool isolation & bucket hygiene** (`invariant_poolIsolationAndBucketHygiene`): every entry in a
   `(poolId, tick)` bucket belongs to that pool (H1/H2), is live (NFT not burned) and unfilled, and
   appears at most once per bucket (M3 swap-and-pop consistency).
3. **Vault-share consistency** (`invariant_vaultSharesConsistent`, vault suite): `Σ order.vaultShares
   == vault.sharesOf(hook)` — no orphaned, drifted, or double-counted shares.

Beyond the coded invariants, auditors should confirm:

4. **Graceful non-revert:** no resting order, extreme-price pool, or failing vault can revert a
   third-party swap. Fills that cannot execute skip cleanly (`OrderExecutionFailed`); vault-redeem
   failures leave the position intact (`VaultRedeemFailed`).
5. **Hard price gate:** a filled order executed at trigger-or-better within `MAX_SLIPPAGE_BPS = 50`
   (0.5%). Large orders may fill **partially**, with the unused input refunded (§9).
6. **Access control:** cancel / claim / deposit gate on `ownerOf`; admin functions gate on `onlyOwner`
   with the exact bounds in §4.5.

The adversarial-review process mutation-tested each coded invariant (injected a bug, confirmed the
invariant fails), so the suite is known to have teeth rather than being vacuously green.

---

## 8. Findings already addressed

All findings from judge feedback + an independent audit-prep scan are fixed on this branch. Compact
summary (each fix has a dedicated commit on branch `fix/pool-isolation-h1-h2` with a full write-up in
its message):

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| **H1** | HIGH | `claimOrder` accepted a caller-chosen `PoolKey` with no order→pool binding → attacker baseline inflates rebate | Order stores `poolId`; `claimOrder` reverts `PoolKeyMismatch` on a foreign key |
| **H2** | HIGH | Tick buckets / active-tick list not namespaced by `PoolId` → cross-pool orders sharing `currency0` collide | All order indexing namespaced by `PoolId`; per-pool sentinels; unsound `token0` filter removed |
| **H3** | HIGH | `forceCancelOrder` could burn NFT without redeeming `vaultShares` → stranded principal | Proven UNREACHABLE: `vaultShares > 0 ⟹ isFilled`, and force-cancel reverts on filled orders. Documented invariant + proving test (admin redeem-and-seize deliberately not added — would be worse centralization) |
| **M1** | MED | `_calculateIL` used output amount as dimensionally-wrong "liquidity" → mispriced rebate | Renamed to `outputNotional` + honest NatSpec; safety comes from the yield cap, not precision |
| **M2** | MED | `pendingFees` + order outputs share one balance → fee withdrawal could eat principal | Structural guard: vault-path payout reverts `RebateExceedsRedeemed` if it would exceed what the vault just delivered; solvency tests + invariant |
| **M3** | MED | Unbounded per-tick arrays; linear-scan cancel/forceCancel → griefing DoS | `orderBucketIndex` + `_removeFromBucket` O(1) swap-and-pop; cancel/forceCancel have no loop |
| **M4** | MED | Fixed 5% internal-swap limit + advisory slippage → orders could close worse than trigger | Hard price gate: internal-swap limit anchored to `triggerPrice` (± 0.5%) via non-reverting `_tolerantSqrtLimit`; forced-fill blocks deleted; two provably zero-delta skip paths |
| **J1** | LOW | LP identity via `hookData` is spoofable | **Removed** — deleted the dead `lpPositions` / `getLPPosition` telemetry; `afterAddLiquidity` is now a no-op (flag retained to keep the deployed hook address valid) |
| **J2** | LOW | IL uses instantaneous spot (no TWAP) → sandwich can inflate computed IL | Accepted (see §9) — `min(yield, IL)` cap + `RebateExceedsRedeemed` bound it to the user's own yield; `sqrtPriceAtFill` captured pre-internal-swap |
| **L1** | LOW | Extreme `triggerPrice` could panic in `uint128ToSqrtPrice` / defeat the M4 gate | `MAX_TRIGGER_PRICE = 1e36` bound in `createLimitOrder` (clean revert before any transfer/mint); makes the M4 overflow clamp dead code for every creatable order |

### 8.1 Internal adversarial audit (2026-08-08)

A second, self-run multi-agent adversarial pass (graded against OpenZeppelin's audit of Uniswap Labs'
DualPoolHook, used as a checklist) surfaced two DoS and three lower items. Each fix ships with a
regression test in `test/AuditP0Regression.t.sol` that **fails on the pre-fix code** and passes after.
**No finding caused fund theft** — the two MEDIUMs are liveness (funds stay recoverable via cancel).

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| **A1** | MED | Active-tick scan counted INELIGIBLE ticks against `MAX_ACTIVE_TICK_SCAN`, so >100 far-side ticks (dust-weaponizable or organic) starved eligible orders → they never filled | `_processTickBucket` returns whether it did eligible work; only such ticks spend a scan slot (PR #21) |
| **A2** | MED | `netAmount.toUint96()` / the push refund could revert uncaught inside `afterSwap`, DoSing the whole user swap on exotic asymmetric-decimal pools | Fill body moved to an external self-gated `_fillOrder` wrapped in try/catch → any fill-path revert degrades to `OrderExecutionFailed` and unwinds the nested PoolManager deltas (PR #21) |
| **A3** | LOW | Execution path holds no ReentrancyGuard lock → a callback token could re-enter cancel/claim/deposit mid-fill and double-spend when the hook custodies another order in the same token | Mutual-exclusion gate: `create/cancel/deposit/claim` revert `ExecutionInProgress()` while `isExecuting` (PR #22) |
| **A4** | LOW | `createLimitOrder` booked the requested `amountIn`, not the measured receipt → fee-on-transfer / rebase tokens over-state custody → last claimant insolvent | Measured-receipt on deposit (`balanceOf` delta), mirroring the claim path; a zero net receipt is rejected |
| **A5** | INFO | A trigger far from baseline lets an owner rebate ALL of their own vault yield → `pendingFees` surplus ≈ 0 | Accepted by design: returning an order's own yield IS the product; protocol revenue is the separate `feeBps` execution fee, not a yield cut. Documented at `_calculateIL` |

> **Deployment note:** these fixes are merged to `main`, but the live Base/Unichain hooks are immutable
> and predate them, so they take effect only on the **next redeploy**. Both existing pools use standard
> tokens (WETH/USDC) at sane prices, where A1 requires a grown book and A2/A4 are unreachable.

---

## 9. Known & accepted risks

These are documented, understood, and accepted as of this submission. **None causes fund loss beyond the
affected user's own funds**; all are candidate items for the auditor to independently re-confirm.

1. **`MIN_ORDER_SIZE` deferred (decimals footgun).** No minimum order size is enforced. A single global
   constant cannot serve both 6-decimal USDC (the live `currency0`) and 18-decimal tokens (`1e15` would
   impose a ~$1B floor on USDC). Anti-dust griefing is instead mitigated by M3's O(1) removal + the
   per-swap gas budget + the real transfer/mint cost of each order. A per-pool/decimal-aware floor is the
   correct future fix.

2. **`netAmount.toUint96()` revert edge (fail-closed).** In `_executeOrder`, a single-order net output
   above ~7.9e28 wei (`type(uint96).max`) would revert the cast. This is **unreachable** for any
   realistic order/pool and is **fail-closed** (reverts rather than silently truncating); it is not
   introduced by any fix. It could, in principle, block that one order's fill on an absurdly large output.

3. **`sqrtPriceToUint128` extreme-pool panic — FIXED (B3).** Previously the `afterSwap` eligibility scan
   converted the post-swap price with the reverting `sqrtPriceToUint128`, which panics (`0x11`) computing
   `sqrtPrice²` for a pool priced above ~1.85e19 — a self-DoS on the griefer's own hook-attached pool
   (H1/H2 isolation already confined it to that pool). The eligibility scan **and** the `OrderFilled`
   event now use the shared saturating `_saturatingPrice` helper (clamps to `type(uint128).max` instead
   of panicking), so a swap on an extreme pool no longer reverts. The saturated value only ever feeds a
   trigger comparison, and any resulting fill stays bounded by the M4 price gate + `min(yield, IL)` +
   `RebateExceedsRedeemed`. The public `sqrtPriceToUint128` is kept (unchanged, strict/reverting) as an
   off-chain utility. Proven by `test_B3_ExtremePricePool_SwapDoesNotRevert` (mutation-verified: reverts
   `0x11` with the old helper).

4. **Partial fills close + refund (no re-queue).** A genuinely eligible order that is larger than the
   pool depth within tolerance fills **partially at trigger-or-better**, refunds the unused input, and
   **closes** — the remainder is **not** re-queued. Re-queuing was rejected because it would overload the
   output-holding `amount0`/`amount1` fields and risk the M2 solvency accounting. This is a UX decision,
   not a safety issue.

5. **IL rebate is a bounded heuristic, not precise IL.** `_calculateIL` returns a 2nd-order Taylor
   (Uniswap-V2 IL-curve) approximation scaled by the order's output notional — valid only for small
   moves (< ~50%), decimals-sensitive, and referenced against the never-updated pool-init
   `sqrtPriceBaseline`. It is used **only** as the upper bound in `rebate = min(yieldEarned, ilAmount)`,
   further capped at the vault's `redeemed` amount. So however the heuristic is sized — or the fill price
   manipulated (J2) — the rebate can never exceed the user's own realized vault yield and can never draw
   from other orders' custody or from fees. The **precision** of the displayed rebate is a disclosed UX
   limitation; the **safety** is structural (M1 + J2 + M2).

6. **M4 overflow clamp is dead code post-L1.** `_tolerantSqrtLimit`'s `priceX192 > type(uint256).max >> 96`
   overflow clamp can no longer be reached by any creatable order, because L1's `MAX_TRIGGER_PRICE = 1e36`
   sits ~18× below the clamp threshold (~1.83e37). It is retained as defense-in-depth.

7. **`sqrtPriceBaseline` is attacker-settable at pool creation (bounded, `_calculateIL` now saturating).**
   The baseline is stamped once in `_afterInitialize`, i.e. at the only moment a pool is provably empty,
   and pool initialization is permissionless on a deterministic `PoolKey` — so a third party (or a
   front-runner of the deployer's own setup script) can fix any pool's baseline at an arbitrary price,
   permanently (no setter; v4 rejects re-initialize). **Value impact is bounded and was already covered:**
   the baseline only feeds `ilAmount`, which is consumed solely as the ceiling in
   `rebate = min(yieldEarned, ilAmount)` and capped again at what the vault delivered — so a poisoned
   baseline can at most let an order owner keep 100% of their *own* vault yield instead of the
   `min(yield, IL)` share, diverting protocol revenue that would otherwise reach `pendingFees`. It can
   never make the hook overpay. **Availability impact is now fixed:** a baseline far *below* the fill
   price used to overflow `outputNotional * diff * diff` and panic (`0x11`) inside `_calculateIL`, which
   `claimOrder` calls unconditionally — permanently stranding every filled order in that pool, since
   `claimOrder` is their only exit (`forceCancelOrder` refuses filled orders and there is no sweep).
   `_calculateIL` is now **saturating** (returning `type(uint256).max` instead of reverting), mirroring
   the `_saturatingPrice` treatment already applied on the swap path; saturation is semantically free
   because the value is a ceiling only. Proven end-to-end by
   `test_M06_PoisonedBaselinePoolStillClaimable` (mutation-verified: panics `0x11` without the guard).
   Neither live deployment is affected — both pools were initialized at sane prices, and a sanely
   initialized pool is immune.

---

## 10. Deployment

**Live on Unichain mainnet (chainId 130):**

| Contract | Address |
|----------|---------|
| `ILAwareLimitOrderHook` | `0x3983130fcd18606afe659acdddb0018d21c254ce` |
| `SimulatedYieldVault` (demo, out of scope) | `0xad5e352E96B972BE0ae1eDd2d1f60E69bf1Ee608` |
| `PoolManager` (v4-core) | `0x1F98400000000000000000000000000000000004` |

- **Pool:** USDC / WETH, `fee = 3000`, `tickSpacing = 60`.
  `poolId = 0x093ab4b09860ac96a823165918b56e35837631d16440daa15385b3f0d7b23279`.
- **Token sort order (important):** on Unichain **USDC is `currency0`** (6 decimals) and **WETH is
  `currency1`** (18 decimals) — the opposite of the Base deployment. This is the decimals footgun
  referenced in §5/§9.
- **Base mainnet (chainId 8453) — production, real Aave vault:** hook
  `0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce` (verified; pool
  `0xc92fdde3c2264c8abe30cea3ee4d3ffeeef6ca009117e843158f8f8a5fe6f03e`) wires `yieldVault` to the REAL Aave USDC Static
  aToken `waBasUSDC` `0xC768c589647798a6EE01A91FdE98EF2ed046DBD6` (ERC-4626, `asset() == USDC`), so the
  yield rebate is funded by real Aave lending, not the demo vault. On Base **WETH is `currency0`** (opposite
  Unichain), so only USDC-output orders route into the vault. The hook bytecode is identical across chains
  (vault-agnostic, immutable `yieldVault`); the earlier Base demo hook `0x45d9…4040` is superseded. Audit
  focus is the single `src/ILAwareLimitOrderHook.sol` regardless of chain or vault.

**Compiler / build settings** (`foundry.toml`):

- `solc = 0.8.26`
- `via_ir = true`
- `evm_version = cancun`
- `optimizer = true`, `optimizer_runs = 200`

---

## 11. How to build & test

```bash
# Build the contract
forge build

# Run the full suite (63 unit/integration + 7 invariants = 70 tests)
forge test -vvv

# Invariant suite only (Phase-2 solvency / pool-isolation / vault-share invariants)
forge test --match-path test/ILAwareLimitOrderHookInvariant.t.sol -vvv
```

Invariant config (in `foundry.toml`): `runs = 128`, `depth = 48`, `fail_on_revert = false`
(intentional — the handler tolerates reverting sub-calls so the graceful-skip and vault-failure paths
are exercised under the invariants).

**Current status: 70 tests passing** (63 unit/integration + 7 Phase-2 invariants: solvency,
pool-isolation / bucket-hygiene, vault-share consistency).

---

## 12. Static analysis (Slither)

Slither `0.11.5` was run over the in-scope contract (`slither . --filter-paths "lib/|test/|script/|frontend/"`).
It produced **26 results, none a real issue** — each was triaged as a false-positive or an intentional,
documented pattern:

| Detector | Where | Triage |
|----------|-------|--------|
| `uninitialized-state` | `tickToOrders` | False positive — a `mapping` is populated by index (`.push` in `createLimitOrder`), never "initialized" wholesale |
| `divide-before-multiply` (×5) | `sqrtPriceToUint128`, `uint128ToSqrtPrice`, `_tolerantSqrtLimit`, `_saturatingPrice`, `_alignTick` | Intentional fixed-point (Q64.96) and tick-alignment math; precision behaviour is understood and documented |
| `reentrancy` (benign, ×3) | `_processTickBucket`, `_tryExecuteOrders` | State updates after `poolManager` calls inside the execution loop, which is guarded by `nonReentrant` + the `isExecuting` flag (see THREAT_MODEL §3.3–3.4) |
| `unused-return` (×3) | `_afterSwap`/`_executeOrder` `getSlot0`; `_executeOrder` `settle()` | Intentional — only the needed slot0 fields are used; `settle()`'s return is not needed (standard v4 pattern) |
| `missing-zero-address` | constructor `_yieldVault` | Intentional — `address(0)` is the valid "no vault" mode, checked before every vault call |
| `dead-code` (×2) | `_tolerantSqrtLimit`, `_saturatingPrice` | False positive (via-IR inlining artifact) — `_tolerantSqrtLimit` is called in `_executeOrder` (~810) and `_saturatingPrice` in `_afterSwap` eligibility (~636) + the `OrderFilled` event (~869/902); covered by the M4 + B3 tests |
| `cyclomatic-complexity` | `_executeOrder` | Informational |

*Auditor action: independently re-run and re-confirm the triage; nothing here required a code change.*
