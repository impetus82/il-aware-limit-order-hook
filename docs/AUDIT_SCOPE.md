# ILAwareLimitOrderHook — Audit Scope

**Prepared for:** external audit firm
**Contact:** egoshin_crypto@proton.me
**Repository state:** branch `fix/pool-isolation-h1-h2`, all 8 findings + L1 fixed, 71 tests passing.
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

`SimulatedYieldVault` is the ERC-4626 vault the live deployment points at. **It is a demo dependency and
is OUT OF SCOPE** (see §3). It is defined only in `script/DeployHookathon.s.sol` and in tests — it is
**not** part of `src/`. The hook treats *any* `yieldVault` address as a trusted-ish external ERC-4626
(see §5); audit effort should focus on the hook's assumptions about the vault, not the mock's internals.

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

- `afterAddLiquidity` records **informational telemetry only** (`lpPositions`) when an LP passes
  `abi.encode(lpAddress)` as `hookData`. **This telemetry is spoofable and is never used for payouts or
  access control** (see J1 in §9). LPs interact with the pool normally; the hook takes no LP funds and
  returns a zero delta from `afterAddLiquidity`.

### 4.5 Hook owner / admin (`Ownable`)

The admin's powers are **deliberately narrow**. Enumerated exactly:

| Function | Exact power | Bound |
|----------|-------------|-------|
| `setFeeBps(uint256)` | Set the per-fill execution fee | **Cannot exceed `MAX_FEE_BPS = 50` (0.5%)** — reverts `FeeTooHigh`. Applies to future fills only. |
| `withdrawFees(Currency, address)` | Withdraw accrued fees | **Can withdraw `pendingFees[currency]` only.** This balance is credited *only* after the matching fee was physically `take`-n into the hook (see M2). It is structurally disjoint from order custody and vault deposits. |
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
  `try/catch` (deposit failure is a no-op that resets approval). `redeem` is wrapped in `try/catch`
  (redeem failure leaves the position fully intact for re-claim, emitting `VaultRedeemFailed`; **no**
  hook balance is paid on that path). The hook assumes the vault does **not** re-enter (it is called
  from `nonReentrant` functions) and that `redeem` returns the assets it transfers. A malicious vault can
  at worst grief its own depositors (deposit/redeem DoS) or return a lossy redeem (handled: user is paid
  exactly `redeemed`); it **cannot** reach other orders' custody (the `RebateExceedsRedeemed` guard, M2).
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
| **`pendingFees`** | Hook balance, per-currency | `withdrawFees` (owner only) |
| **Vault shares** | Held by the hook in the vault; each share backed by exactly one live order | tracked by `order.vaultShares`; §7 invariant |

---

## 7. Security properties / invariants to verify

The properties below are asserted by `test/ILAwareLimitOrderHookInvariant.t.sol` (Foundry invariant
suite: `runs = 128`, `depth = 48`, `fail_on_revert = false`). The suite runs one hook across **two pools
sharing `currency0`** — the exact H1/H2 collision shape — in both a no-vault and a yielding-vault
configuration.

1. **Solvency** (`invariant_solvency`): for every currency,
   `balanceOf(hook) >= custody(unfilled orders) + output(filled-unclaimed orders) + pendingFees`.
   Vault-deposited outputs are excluded (backed by the vault, not the hook balance). `>=` rather than
   `==` because un-rebated yield accretes as a safe surplus.
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
| **J1** | LOW | LP identity via `hookData` is spoofable | Accepted (see §9) — `lpPositions` is dead telemetry, never gates payouts |
| **J2** | LOW | IL uses instantaneous spot (no TWAP) → sandwich can inflate computed IL | Accepted (see §9) — `min(yield, IL)` cap + `RebateExceedsRedeemed` bound it to the user's own yield; `sqrtPriceAtFill` captured pre-internal-swap |
| **L1** | LOW | Extreme `triggerPrice` could panic in `uint128ToSqrtPrice` / defeat the M4 gate | `MAX_TRIGGER_PRICE = 1e36` bound in `createLimitOrder` (clean revert before any transfer/mint); makes the M4 overflow clamp dead code for every creatable order |

---

## 9. Known & accepted risks

These are documented, understood, and accepted as of this submission. **None causes fund loss beyond the
affected user's own funds**; all are candidate items for the auditor to independently re-confirm.

1. **`lpPositions` / J1 — spoofable telemetry (deliberately NOT removed).** `afterAddLiquidity` still
   populates `lpPositions[poolId][lp]` from caller-supplied `hookData`, and `getLPPosition` still exposes
   it. This data is **informational only** — it is never read for payouts, rebate sizing, or access
   control (all payouts gate on `ownerOf` + the `min(yield, IL)` rebate cap). It is spoofable (anyone can
   claim any LP identity), but spoofing it changes nothing on-chain. J1's planned deletion was **not**
   performed; the code path is retained. *Auditor action: confirm no code path consumes `lpPositions` for
   value.*

2. **`MIN_ORDER_SIZE` deferred (decimals footgun).** No minimum order size is enforced. A single global
   constant cannot serve both 6-decimal USDC (the live `currency0`) and 18-decimal tokens (`1e15` would
   impose a ~$1B floor on USDC). Anti-dust griefing is instead mitigated by M3's O(1) removal + the
   per-swap gas budget + the real transfer/mint cost of each order. A per-pool/decimal-aware floor is the
   correct future fix.

3. **`netAmount.toUint96()` revert edge (fail-closed).** In `_executeOrder`, a single-order net output
   above ~7.9e28 wei (`type(uint96).max`) would revert the cast. This is **unreachable** for any
   realistic order/pool and is **fail-closed** (reverts rather than silently truncating); it is not
   introduced by any fix. It could, in principle, block that one order's fill on an absurdly large output.

4. **`sqrtPriceToUint128` panic on an extreme own-pool.** The reverting price helper used for
   `afterSwap` eligibility panics (`0x11`) when computing `sqrtPrice²` for a pool priced above
   ~1.85e19. This is a **self-DoS confined to a griefer's OWN hook-attached pool** — H1/H2 pool
   isolation means it cannot affect any other pool's orders or swaps. Event fields use the saturating
   `_executionPrice` helper instead, so the *fill* path does not inherit this revert.

5. **Partial fills close + refund (no re-queue).** A genuinely eligible order that is larger than the
   pool depth within tolerance fills **partially at trigger-or-better**, refunds the unused input, and
   **closes** — the remainder is **not** re-queued. Re-queuing was rejected because it would overload the
   output-holding `amount0`/`amount1` fields and risk the M2 solvency accounting. This is a UX decision,
   not a safety issue.

6. **IL rebate is a bounded heuristic, not precise IL.** `_calculateIL` returns a 2nd-order Taylor
   (Uniswap-V2 IL-curve) approximation scaled by the order's output notional — valid only for small
   moves (< ~50%), decimals-sensitive, and referenced against the never-updated pool-init
   `sqrtPriceBaseline`. It is used **only** as the upper bound in `rebate = min(yieldEarned, ilAmount)`,
   further capped at the vault's `redeemed` amount. So however the heuristic is sized — or the fill price
   manipulated (J2) — the rebate can never exceed the user's own realized vault yield and can never draw
   from other orders' custody or from fees. The **precision** of the displayed rebate is a disclosed UX
   limitation; the **safety** is structural (M1 + J2 + M2).

7. **M4 overflow clamp is dead code post-L1.** `_tolerantSqrtLimit`'s `priceX192 > type(uint256).max >> 96`
   overflow clamp can no longer be reached by any creatable order, because L1's `MAX_TRIGGER_PRICE = 1e36`
   sits ~18× below the clamp threshold (~1.83e37). It is retained as defense-in-depth.

---

## 10. Deployment

**Live on Unichain mainnet (chainId 130):**

| Contract | Address |
|----------|---------|
| `ILAwareLimitOrderHook` | `0x8C19f1641946c662308000bB4E2Eaf684c81d4CE` |
| `SimulatedYieldVault` (demo, out of scope) | `0xceee912C708516624E9aC5581c8FCC93eA8eE79d` |
| `PoolManager` (v4-core) | `0x1F98400000000000000000000000000000000004` |

- **Pool:** USDC / WETH, `fee = 3000`, `tickSpacing = 60`.
  `poolId = 0xe1d695d4c147091549aeb6f9e78521a0184a1e7e272a71c12e708c881981f6ba`.
- **Token sort order (important):** on Unichain **USDC is `currency0`** (6 decimals) and **WETH is
  `currency1`** (18 decimals) — the opposite of the Base deployment. This is the decimals footgun
  referenced in §5/§9.
- A second deployment exists on Base mainnet (chainId 8453, hook
  `0x45d971BdE51dd5E109036aB70a4E0b0eD2Dc4040`) where WETH is `currency0`; audit focus is the Unichain
  deployment.

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

# Run the full suite (64 unit + 7 invariants = 71 tests)
forge test -vvv

# Invariant suite only (Phase-2 solvency / pool-isolation / vault-share invariants)
forge test --match-path test/ILAwareLimitOrderHookInvariant.t.sol -vvv
```

Invariant config (in `foundry.toml`): `runs = 128`, `depth = 48`, `fail_on_revert = false`
(intentional — the handler tolerates reverting sub-calls so the graceful-skip and vault-failure paths
are exercised under the invariants).

**Current status: 71 tests passing** (64 unit + 7 Phase-2 invariants: solvency, pool-isolation /
bucket-hygiene, vault-share consistency).
