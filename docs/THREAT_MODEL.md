# ILAwareLimitOrderHook — Threat Model

**Contract:** `src/ILAwareLimitOrderHook.sol`
**Type:** Uniswap V4 hook + ERC-721 order registry + ERC-4626 yield integration
**Deployment (live):** Unichain mainnet (chainId 130)
- Hook: `0x8C19f1641946c662308000bB4E2Eaf684c81d4CE`
- SimulatedYieldVault (ERC-4626, ~3% simulated APY): `0xceee912C708516624E9aC5581c8FCC93eA8eE79d`
- Pool: USDC/WETH, `currency0 = USDC` (6 decimals), `currency1 = WETH` (18 decimals)

**Status:** All security findings from the audit-prep scan (H1, H2, H3, M1, M2, M3, M4, J1, J2, L1) are fixed — including J1 (the spoofable `lpPositions` telemetry was removed). 70 tests pass (63 unit/integration + 7 Phase-2 invariants: solvency, pool-isolation/bucket-hygiene, vault-share consistency). This document is grounded line-by-line in the deployed source; it is the companion to `docs/AUDIT_SCOPE.md` (scope, actors, assets at risk) and `test/ILAwareLimitOrderHookInvariant.t.sol` (Phase-2 invariants). Per-finding write-ups live in the `fix/pool-isolation-h1-h2` commit history.

> **Canonical function signature.** The one function whose signature is most easily misremembered:
> ```solidity
> function createLimitOrder(
>     PoolKey calldata poolKey,
>     bool zeroForOne,
>     uint96 amountIn,
>     uint128 triggerPrice
> ) external returns (uint256 orderId);
> ```
> The README's parameter list is **wrong** and must be corrected against this signature. `claimOrder(uint256 orderId, PoolKey calldata poolKey)` requires the full `PoolKey` tuple (H1 binding).

---

## 1. Actors & Incentives

| Actor | Capabilities | Incentive | Trust assumption |
|-------|-------------|-----------|------------------|
| **Order creator / NFT owner** | `createLimitOrder`, `cancelOrder`, `depositToVault`, `claimOrder`. Holds an ERC-721 (`orderId == tokenId`) that is the sole bearer claim on the order and its output. | Get a limit order filled at trigger-or-better; optionally earn vault yield on the parked output; claim principal + a yield-capped rebate. | Trusted only over *their own* order — every state-changing call gates on `ownerOf(orderId) == msg.sender`. |
| **NFT transferee** | Anyone the creator transfers the ERC-721 to inherits full control (cancel/deposit/claim). | Buy/sell an open or filled position as a bearer asset. | Same as creator; the contract never stores a `creator` address, so ownership *is* current `ownerOf`. This is intentional (M-tier note: no stale-creator griefing). |
| **Swapper (any pool user)** | Executes ordinary V4 swaps. Their swap is the *trigger*: `_afterSwap` runs the hook's execution loop against resting orders. | Trade normally. Has **no** interest in order execution and must never be harmed by it. | Untrusted. The central anti-DoS property is that a swapper's transaction can never be reverted or meaningfully overcharged by any resting order (see §3.3). |
| **Hook owner (admin)** | `setFeeBps` (0–50 BPS), `withdrawFees`, `forceCancelOrder`. `Ownable`, currently the EOA deployer. | Operate the protocol; collect execution fees; clean up genuinely stuck (unfilled) orders. | Semi-trusted. Powers are deliberately bounded: cannot touch filled-order output, cannot exceed `MAX_FEE_BPS`, cannot withdraw beyond `pendingFees`. See §3.5 and the admin attack rows in §4. |
| **Uniswap V4 PoolManager** | Custodies pool liquidity; the hook calls `swap`/`sync`/`settle`/`take`/`getSlot0` inside the unlock. | N/A (protocol). | Trusted as the V4 core. The hook assumes PoolManager semantics (flash-accounting, `CurrencyNotSettled` enforcement, `PriceLimitAlreadyExceeded` reverts). |
| **ERC-4626 yield vault** | Receives `deposit`, honors `redeem`. Base: real Aave `waBasUSDC`; Unichain: `SimulatedYieldVault` (simulated 3% APY). | N/A. | **Semi-trusted / possibly hostile.** The hook is written so a reverting, lossy, **or over-reporting** vault cannot break solvency or strand other users: the claim payout is priced from `min(reported, measured balance delta)`, deposits that credit zero shares are rejected (`ZeroSharesMinted`), and the approval is zeroed on both deposit outcomes so no standing allowance survives (see §3.1 vault path, §4 vault-redeem-revert). |
| **Griefer** | Any of: a swapper trying to DoS the pool via a toxic resting order; a spammer flooding tick buckets; an operator of a maliciously-priced *sibling* pool. | Deny service, waste gas, or exploit shared state across pools. | Untrusted and explicitly modeled — the H1/H2/M3/M4 fixes exist to neutralize this actor. |

---

## 2. Attack Surface

Every externally reachable entry point, and what an attacker controls at each.

### 2.1 `createLimitOrder(poolKey, zeroForOne, amountIn, triggerPrice)` — `external nonReentrant`
Caller fully controls `poolKey`, direction, amount, and trigger. Effects: pulls `amountIn` of the input token into hook custody, mints the ERC-721, indexes the order into a `(PoolId, alignedTick)` bucket, and links the tick into the pool's sorted active-tick list.
- **Validation:** `amountIn != 0`, `triggerPrice != 0`, `triggerPrice <= MAX_TRIGGER_PRICE (1e36)` (L1), `poolKey.tickSpacing > 0`.
- **Attacker levers:** arbitrary `poolKey` (including a pool never initialized through this hook — handled by `_ensurePoolSentinels`); absurd `triggerPrice` (bounded by L1); dust amounts (no `MIN_ORDER_SIZE` — accepted risk). Reentrancy is blocked by `nonReentrant` (ERC-777 input-token defense) before any state mutation.

### 2.2 The `afterSwap` execution path — `_afterSwap` → `_tryExecuteOrders` → `_processTickBucket` → `_executeOrder`
Triggered by **any** swap on a hooked pool; the swapper does not choose which orders run. This is the most safety-critical surface because it executes on a third party's transaction.
- `_afterSwap` short-circuits if `isExecuting` (re-entry from the hook's own internal swap), reads post-swap `sqrtPriceX96`/tick, and walks the pool's active-tick list in the direction implied by the swap.
- `_tryExecuteOrders` refuses to walk an uninitialized list (`poolListInitialized` guard), caps at `MAX_ACTIVE_TICK_SCAN = 100` populated ticks, and breaks when `gasleft() < GAS_LIMIT_PER_ORDER (150k)`.
- `_processTickBucket` lazily evicts filled/burned orders, checks price eligibility, and calls `_executeOrder`, which **returns `bool` and never reverts the outer swap**.
- **Attacker levers:** plant a resting order designed to fail or consume gas. Neutralized by graceful execution + gas budget + the M4 price gate (§3.3).

### 2.3 The internal fill swap — inside `_executeOrder`
The hook itself calls `poolManager.swap(poolKey, …)` with an `sqrtPriceLimitX96` anchored to the order's `triggerPrice ± MAX_SLIPPAGE_BPS` via `_tolerantSqrtLimit` (M4). It then settles the *actual consumed* input (from `swapDelta`, not `amountIn`), takes the output (minus fee) into hook custody, marks the order filled, and refunds any unconsumed input on a partial fill.
- **Attacker levers:** manipulate spot before the trigger so the fill runs at a bad price. Neutralized because the limit is anchored to trigger, not spot: the swap is *physically* unable to execute worse than trigger-within-tolerance (§3.3). Two provably zero-delta skip paths (Stage A pre-swap, Stage B `actualInput == 0`) avoid `PriceLimitAlreadyExceeded`/over-settlement DoS.

### 2.4 `claimOrder(orderId, poolKey)` — `external nonReentrant`
Owner-only settlement of a filled order. Reverts unless `isFilled`, `ownerOf == msg.sender`, and **`poolKey.toId() == order.poolId`** (H1 `PoolKeyMismatch`). Computes the IL rebate heuristic against `sqrtPriceBaseline[poolId]` and `order.sqrtPriceAtFill`. If the output was deposited (`vaultShares > 0`), redeems from the vault and pays `output + min(yield, IL)` — hard-capped at `redeemed` (M2 `RebateExceedsRedeemed`). A reverting vault redeem leaves the position fully intact and emits `VaultRedeemFailed`.
- **Attacker levers:** supply a foreign `poolKey` to inflate the baseline (blocked by H1); manipulate spot to inflate IL (bounded by the yield cap + `redeemed` cap, §3.6); reenter (blocked by `nonReentrant`).

### 2.5 `depositToVault(orderId)` — `external nonReentrant`
Owner-only; requires `isFilled`. Force-approves the output token to the vault and deposits, recording `vaultShares` on success; on vault failure it resets the approval and no-ops (graceful). Idempotent-ish (`vaultShares > 0` early-returns).
- **Attacker levers:** hostile vault. Failure is caught; the output stays in hook custody and remains claimable.

### 2.6 Admin functions — `setFeeBps`, `withdrawFees`, `forceCancelOrder` (`onlyOwner`)
- `setFeeBps`: bounded by `MAX_FEE_BPS = 50` BPS.
- `withdrawFees`: transfers only `pendingFees[currency]` — the per-fill execution fees plus the un-rebated vault yield captured on claim — each credited *solely* after the matching physical `take`/`redeem`; structurally cannot touch order custody (§3.1, M2).
- `forceCancelOrder`: only **unfilled** orders (`isFilled` guard + `_ownerOf != 0`), returns input to the current NFT owner, burns. Cannot reach a vault-backed position because `vaultShares > 0 ⟹ isFilled` (H3 monotonic invariant), so no principal can be stranded and the admin cannot seize a filled position.

### 2.7 `afterAddLiquidity` — no-op (J1 removed)
`_afterAddLiquidity` is a no-op returning a zero delta. The earlier `lpPositions` / `getLPPosition` telemetry — an `LPPosition` keyed by an LP address decoded from **unauthenticated `hookData`** (spoofable, and never read by any payout, access-control, eligibility, or accounting path) — was **removed** (finding J1). The permission flag is retained only to keep the deployed hook address valid, so this is no longer an attack surface.

---

## 3. Core Security Properties (and why they hold)

Each property is tied to the concrete mechanism that enforces it and the finding/invariant that covers it.

### 3.1 Solvency — the hook always holds at least what it owes, per currency
**Property.** For every currency, `balanceOf(hook) >= Σ(unfilled-order input custody) + Σ(filled-unclaimed output) + pendingFees`, with vault-deposited outputs excluded (the vault backs them). `pendingFees` now includes the un-rebated vault yield (captured on claim, no longer stranded); `>=` rather than `==` remains only because ERC-4626 share-redemption rounding can leave sub-wei dust as a safe surplus.

**Why it holds — three separated pots, no shared draw:**
1. **Input custody** is taken in `createLimitOrder` and only ever returned to the owner (cancel/forceCancel) or consumed by the fill swap (`settle` of the *actual* delta).
2. **Filled output** is `take`n into the hook in `_executeOrder` and recorded in `order.amount0/amount1`; it leaves only via `claimOrder` to the owner.
3. **Fees** are `take`n *separately* and credited to `pendingFees[currency]` **only after** the physical take; the un-rebated vault yield is likewise credited to `pendingFees` **only after** the vault `redeem` has physically delivered it (`surplus = redeemed - totalOut`, so the credit is fully backed). `withdrawFees` touches nothing but `pendingFees`. This is why fee withdrawal cannot eat principal (M2, `test_M2_WithdrawFees_CannotEatOrderPrincipal`).

**Rebate is structurally self-funded.** In the vault claim path the payout is funded *only* by what the vault delivered this transaction; `if (totalOut > redeemed) revert RebateExceedsRedeemed()` (M2) makes "the rebate never draws from other orders or from fees" hold **by construction**, not by arithmetic coincidence of the IL formula. A future change to the IL heuristic cannot silently break solvency. The rebate is additionally capped at `min(yieldEarned, ilAmount)`, so it never exceeds the user's own realized yield.

**Covered by:** M2; `invariant_solvency`, `invariant_vaultSharesConsistent` (Phase-2, mutation-verified against injected bugs).

### 3.2 Pool isolation — orders can only ever interact with their own pool
**Property.** An order created for pool X can never be filled against, or claimed against, pool Y — even when X and Y share `currency0` (the exact H1/H2 collision shape: on Unichain both a USDC/WETH and any USDC/T pool share USDC as `currency0`).

**Why it holds:**
- All order indexing is **namespaced by `PoolId`**: `tickToOrders[poolId][tick]`, `orderTickBucket`, and the active-tick linked list (`nextActiveTick[poolId]`, `prevActiveTick[poolId]`, `isActiveTick[poolId]`) are all per-pool (H2). The old unsound `order.token0`-only filter is gone; a bucket entry *provably* belongs to its pool.
- Each order stores `order.poolId`, bound at creation (H1). `claimOrder` reverts `PoolKeyMismatch` unless the caller's `poolKey.toId()` equals `order.poolId`, so an attacker cannot supply a foreign pool's baseline to inflate the rebate.
- Each pool's list has its own sentinels via `_ensurePoolSentinels`, guarding the default-zero trap (an uninitialized `nextActiveTick[poolId][SENTINEL_MIN] == 0` would be a *valid* tick).

**Covered by:** H1, H2; `invariant_poolIsolationAndBucketHygiene` (every bucket entry belongs to its pool, is live + unfilled, and unique).

### 3.3 Graceful execution / anti-DoS — a swapper's transaction is never held hostage
**Property.** No resting order can revert, brick, or meaningfully tax a third party's triggering swap. Orders that cannot fill within tolerance are skipped and left resting; the swap always completes.

**Why it holds:**
- `_executeOrder` returns `bool success`; `_processTickBucket` removes on success and simply `i++`s on failure (order stays for retry). A failing order emits `OrderExecutionFailed` and does **not** revert the loop.
- **M4 hard price gate.** The internal-swap `sqrtPriceLimitX96` is anchored to the order's own `triggerPrice ± MAX_SLIPPAGE_BPS` (`_tolerantSqrtLimit`), not to spot. The swap is therefore physically unable to execute worse than the user's price. An out-of-tolerance order *skips* (zero delta) rather than filling worse-than-trigger — this replaced the old advisory "fill anyway on `SlippageExceeded`" behavior.
- `_tolerantSqrtLimit` is **non-reverting**: the tolerant multiply fits `uint256`, the overflow case is clamped to the correct pool bound per direction (floor for SELL, ceiling for BUY), and the result is clamped into `[MIN_SQRT_PRICE+1, MAX_SQRT_PRICE-1]`. Two zero-delta skip paths (Stage A: limit already on the wrong side of spot → avoid `PriceLimitAlreadyExceeded`; Stage B: `actualInput == 0` → no `settle`/`take`) return cleanly with no `CurrencyNotSettled`.
- **Price cast is saturating (B3).** Both the `afterSwap` eligibility scan and `OrderFilled.executionPrice` use the shared saturating `_saturatingPrice`, so an extreme-price pool cannot revert (DoS) the swap or the fill path. The public `sqrtPriceToUint128` stays strict/reverting as an off-chain utility; the only remaining intentional revert is the fail-closed `netAmount.toUint96()` on an unreachable >~7.9e28-wei output.
- **Gas budget.** `_tryExecuteOrders` caps at 100 populated ticks and both loops break when `gasleft() < 150k`, so a large or spammed order book cannot force an out-of-gas revert on the swapper — remaining orders simply persist.

**Covered by:** M4, M3; the graceful paths are exercised under all Phase-2 invariants (vault-revert, lossy redeem, and M4 partial fills).

### 3.4 Reentrancy safety
**Property.** No external callback can reenter to double-spend, double-fill, or corrupt accounting.

**Why it holds:** `createLimitOrder`, `cancelOrder`, `claimOrder`, and `depositToVault` are `nonReentrant` (OpenZeppelin), defending against ERC-777/hostile-token callbacks during `transferFrom`/`transfer`. Independently, the `isExecuting` flag makes `_afterSwap` a no-op during the hook's own internal `poolManager.swap`, preventing the fill path from recursively re-entering the execution loop. `claimOrder` mutates state (zeroes amounts, burns the NFT) *before* the external `safeTransfer`, and the vault-redeem path zeroes `vaultShares` before settling.

**Covered by:** design; upheld throughout the invariant suite (no reentrancy break observed under random sequences).

### 3.5 Access control via ERC-721 ownership (no creator storage)
**Property.** Only the current holder of the position NFT can cancel, deposit, or claim it; there is no separate, stale "creator" who retains rights after transfer.

**Why it holds:** the `creator` field was removed; ownership is *defined* as `ownerOf(orderId)`. Every user-facing state change checks `ownerOf(orderId) == msg.sender` (or, in `_executeOrder`, captures `ownerOf` at fill time for refunds/events). Burning the NFT (`cancel`/`forceCancel`/`claim`) is the canonical "position closed" signal, and `_ownerOf(orderId) == address(0)` is the burned check used for lazy bucket cleanup. Admin `forceCancelOrder` returns funds to the *current* NFT owner, not a stored creator.

**Covered by:** H3 (admin bound); consistent with the ownership model throughout.

### 3.6 IL / price-manipulation resistance
**Property.** No amount of price manipulation (including a sandwich around the fill) can turn the IL rebate into theft from the protocol or from other users.

**Why it holds:** `_calculateIL` is an explicitly-documented **rebate-sizing heuristic** (2nd-order Taylor of the V2 IL curve, valid for <50% moves), *not* a precise IL figure and *not* Uniswap liquidity `L`. Its output is consumed only as the upper bound in `rebate = min(yieldEarned, ilAmount)`, and the vault-path payout is further hard-capped at `redeemed` (§3.1). Therefore, however the heuristic is sized and however spot is manipulated, the rebate can never exceed the user's **own realized vault yield**, and can never draw from other orders' custody or from fees. `order.sqrtPriceAtFill` is captured **before** the hook's own internal swap, so the fill price has no self-inflicted skew (J2). A precise on-chain IL/TWAP oracle was judged disproportionate precisely because the payout is yield-capped.

**Covered by:** M1, J2; `invariant_solvency` holds under yield, loss, and manipulation.

---

## 4. Concrete Attack Scenarios

| # | Attack vector | Why it fails / mitigation | Covered by |
|---|---------------|---------------------------|------------|
| **A1** | **Cross-pool fill.** Attacker opens pool B sharing `currency0` with the real pool A, hoping a swap on B fills A's orders (or vice versa) against a favorable price. | Indexing is `PoolId`-namespaced; B's active-tick list and buckets are disjoint from A's. A's orders are never in B's walk, so B's swap cannot see them. | H2, `invariant_poolIsolationAndBucketHygiene` |
| **A2** | **Cross-pool claim / baseline spoof.** Owner of a filled order calls `claimOrder(orderId, foreignPoolKey)` to use a distant pool's `sqrtPriceBaseline` and inflate the IL rebate. | `claimOrder` reverts `PoolKeyMismatch` unless `poolKey.toId() == order.poolId`. The baseline is forced to the order's real pool. | H1 |
| **A3** | **Fee eats principal.** Admin calls `withdrawFees` hoping to drain funds that back user orders. | `withdrawFees` transfers only `pendingFees[currency]`, credited exclusively after the matching separate `take` in `_executeOrder`. Order inputs/outputs are tracked and held independently. | M2, `test_M2_WithdrawFees_CannotEatOrderPrincipal`, `invariant_solvency` |
| **A4** | **Force-cancel strands vault principal.** Admin force-cancels a vault-deposited order, burning the NFT while `vaultShares` are locked in the vault → principal lost. | Unreachable: `vaultShares > 0 ⟹ isFilled == true` (set only by `depositToVault`, which requires `isFilled`; `isFilled` is monotonic). `forceCancelOrder` reverts `OrderAlreadyFilled` on any filled order, so it can never reach a vault-backed position. | H3, `test_H3_ForceCancel_CannotStrandVaultShares` |
| **A5** | **Griefing DoS via a toxic order.** Attacker plants a resting order engineered to revert or run out of gas during execution, aiming to brick every swap in the pool. | `_executeOrder` returns `bool` and never reverts the swap; a failing order emits `OrderExecutionFailed` and is left resting. The M4 gate makes an unfillable order a clean zero-delta skip. The gas budget (100-tick cap + 150k `gasleft` break) bounds work per swap. | M4, M3 |
| **A6** | **Sandwich to inflate IL.** Attacker sandwiches the fill to push spot far from `sqrtPriceBaseline`, maximizing the computed `ilAmount` and hence the rebate. | Rebate saturates at `min(yieldEarned, ilAmount)` and is hard-capped at `redeemed`. Inflated IL only raises the rebate up to the user's *own* realized yield — never beyond, never from others. `sqrtPriceAtFill` is pre-internal-swap (no self-skew). | J2, M1, `invariant_solvency` |
| **A7** | **Vault redeem reverts on claim.** A hostile/broken vault reverts `redeem` during `claimOrder`, hoping to trap funds or force the hook to pay the principal out of *other* orders' custody. | The `try/catch` leaves the position **fully intact** (NFT, amounts, `vaultShares` untouched), emits `VaultRedeemFailed`, and returns without mutating state or paying from the hook balance. The owner re-claims when the vault recovers. No other order's custody is touched. | design, `invariant_solvency` under `setFailRedeem` |
| **A8** | **Absurd trigger price.** Attacker (or a careless user) submits a `triggerPrice` near `uint128.max` to panic `uint128ToSqrtPrice` at creation, or to push the M4 gate into its overflow clamp and lose floor/ceiling protection. | `createLimitOrder` rejects `triggerPrice > MAX_TRIGGER_PRICE (1e36)` **before** any transfer or mint (clean `InvalidTriggerPrice` revert). `1e36·1.005` sits ~18× below the `_tolerantSqrtLimit` clamp threshold, so that clamp is now dead code for every creatable order. `1e36` is ~2.8e14× above WETH/USDC — nothing realistic is rejected. | L1, `test_L1_RejectsExcessiveTriggerPrice` |
| **A9** | **Dust griefing.** Attacker floods a tick bucket with thousands of dust orders, or the same tick with many orders, to make cancel/execution scans O(n) and expensive. | Bucket removal is O(1) swap-and-pop via `orderBucketIndex` (M3), so cancel/forceCancel have no linear scan to grief. Execution scan is bounded (100 ticks + gas break). Each order still costs a real `transferFrom` + `_mint`, and `userOrders` is never iterated on-chain. Residual: no `MIN_ORDER_SIZE` — accepted (see §5). | M3 |
| **A10** | **Reentrancy via hostile token/vault.** ERC-777-style input token re-enters `createLimitOrder`/`cancelOrder`, or the vault re-enters during deposit/claim, to double-fill or double-refund. | `nonReentrant` on all four user entry points; `isExecuting` blocks re-entry of the execution loop from the hook's internal swap; state is mutated before external transfers in `claimOrder`. | design |
| **A11** | **Partial-fill accounting abuse.** Attacker places an order larger than tolerance-band depth so it only partially fills, hoping the refund/accounting mismatches leave a solvency gap. | The fill settles the *actual* swap delta (not `amountIn`); unused input is refunded to the owner; only the net output is recorded. Partial-fill orders close (remainder is **not** re-queued — a conscious choice to avoid overloading the output-holding `amount0/amount1` fields and risking M2). | M4, `test_M4_HardGate_PartialFillProtectsPrice`, `invariant_solvency` under large orders |
| **A12** | **Poisoned pool baseline.** Attacker permissionlessly initializes a pool on this hook at an extreme price (e.g. `MIN_SQRT_PRICE`), front-running the deployer's own setup script if needed, so `sqrtPriceBaseline` is fixed at the bottom forever. Ordinary trading then drags spot up to a normal-looking price and victims' orders fill far above the baseline. | **Value:** none — the baseline only feeds `ilAmount`, a ceiling consumed as `min(yieldEarned, ilAmount)` and re-capped at what the vault delivered, so the hook can never overpay; the worst case is an order owner keeping all of their *own* yield instead of the protocol's share. **Availability:** `_calculateIL` is **saturating**, so the `outputNotional · diff²` overflow that previously panicked (`0x11`) inside the unconditional `claimOrder` call — permanently stranding every filled order in that pool, `forceCancelOrder` refusing filled orders and there being no sweep — can no longer occur. | §5.7, `test_M06_PoisonedBaselinePoolStillClaimable` (mutation-verified) |
| **A13** | **Over-reporting vault.** A hostile vault returns a `redeemed` value far larger than the assets it actually transferred, aiming to have the hook pay the inflated rebate out of other orders' custody and to credit unbacked `pendingFees`. | The payout is priced from `min(reported, measured balance delta)`, so every branch — the rebate, the `RebateExceedsRedeemed` guard, and the `surplus → pendingFees` credit — binds against tokens the hook physically holds. Reading the delta is safe here (unlike a pro-rata denominator): a donation can only inflate `received`, and `min` then selects `reported`. | M2, `invariant_solvency` |

---

## 5. Accepted Risks (conscious tradeoffs)

These are known, deliberately un-remediated, and documented so an auditor sees them as decisions rather than oversights. None is a fund-loss vector.

1. **No `MIN_ORDER_SIZE`.** A single global minimum cannot serve both 6-decimal USDC (the live Unichain `currency0`) and 18-decimal tokens — e.g. `1e15` would impose a ~$1B floor on USDC orders (a decimals footgun). Anti-dust griefing is already mitigated by M3 (O(1) removal) + the per-swap gas budget + the real `transferFrom`/`_mint` cost of each order. If added later it must be per-pool / decimal-aware.

2. **Partial fills close-and-refund (no re-queue).** A partially filled order is marked filled and refunds the unconsumed input rather than re-resting the remainder. Re-queuing would overload the dual-purpose `amount0/amount1` fields (input custody vs. output) and risk the M2 solvency invariant. The fill is still at trigger-or-better within tolerance; the user simply re-submits the remainder if desired.

3. **`netAmount.toUint96()` can revert on an unreachable single-order output.** A single order producing `> ~7.9e28` wei of output would revert the `toUint96` cast in `_executeOrder`. This is **fail-closed** (no silent loss) and unreachable for any realistic pair/size (`uint96` output ≈ 7.9e10 tokens at 18 decimals). Not introduced by any fix; left as-is because it cannot cause loss.

4. **`sqrtPriceToUint128` extreme-pool panic — FIXED (B3).** The `afterSwap` eligibility scan previously converted the post-swap price with the reverting `sqrtPriceToUint128`, whose `sqrtPrice²` step panics for a pool priced above ~1.85e19 — a self-DoS confined to the griefer's own hooked pool (H1/H2 isolation). Both the eligibility scan and the event field now use the saturating `_saturatingPrice`, so extreme pools no longer revert; the saturated value only feeds a trigger comparison and every fill stays bounded by the M4 gate + `min(yield, IL)` + `RebateExceedsRedeemed`.

5. **M4 `_tolerantSqrtLimit` overflow clamp is dead code.** After the L1 `MAX_TRIGGER_PRICE = 1e36` bound, the `priceX192 > type(uint256).max >> 96` clamp branch in `_tolerantSqrtLimit` is provably unreachable for every creatable order (the tolerant price stays ~18× below the overflow point). It is retained as defense-in-depth, not relied upon.

6. **IL is a bounded heuristic, not precise IL (J2 / M1 residual).** `_calculateIL` is a 2nd-order Taylor approximation of the V2 IL curve scaled by output notional, referenced against the never-updated pool-init baseline, valid only for <50% moves (underestimates beyond). Its **accuracy** is a disclosed UX limitation, not a safety issue: the payout is hard-capped at the user's realized vault yield and at `redeemed`, so imprecision or manipulation can only change the *size* of a self-funded rebate, never cause fund loss. A full oracle was judged disproportionate for a yield-capped rebate.

7. **Admin trust surface.** The `Ownable` owner can set fees (≤ 50 BPS), withdraw accrued fees, and force-cancel **unfilled** orders (funds always returned to the current NFT owner). The owner **cannot** touch filled-order output, exceed `MAX_FEE_BPS`, withdraw beyond `pendingFees`, or seize a vault-backed position. This bounded admin power is the intended trust model for the current single-EOA deployment; a production deployment should move ownership to a timelock/multisig.
