# Audit Scope — LimitOrderHook

**Prepared:** April 2026
**Author:** Yuri (Tonchain)
**Repository:** [github.com/impetus82/limit-order-hook-v4](https://github.com/impetus82/limit-order-hook-v4)

---

## Target Contract

| Item | Detail |
|------|--------|
| File | `src/LimitOrderHook.sol` |
| Lines of Code | ~960 (single file, no external library files) |
| Solidity Version | 0.8.26 |
| EVM Target | Default (Cancun, via Foundry) |
| License | MIT |

This is the **only contract in scope**. Deployment scripts and test files are out of scope.

---

## External Dependencies

| Library | Source | Usage |
|---------|--------|-------|
| `BaseHook` | `v4-periphery/src/utils/BaseHook.sol` | Hook lifecycle (getHookPermissions, afterSwap callback) |
| `IPoolManager` | `v4-core/src/interfaces/IPoolManager.sol` | Pool interactions (swap, settle, take) |
| `StateLibrary` | `v4-core/src/libraries/StateLibrary.sol` | Read pool slot0 (current tick) |
| `TickMath` | `v4-core/src/libraries/TickMath.sol` | Tick-to-sqrtPrice conversion |
| `SafeERC20` | `@openzeppelin/contracts 5.x` | Safe token transfers |
| `ReentrancyGuard` | `@openzeppelin/contracts 5.x` | Reentrancy protection |
| `Ownable` | `@openzeppelin/contracts 5.x` | Access control |
| `SafeCast` | `@openzeppelin/contracts 5.x` | Safe integer conversions |

All Uniswap V4 dependencies are pinned via Foundry submodules (see `foundry.toml` remappings). OpenZeppelin is v5.x via the same mechanism.

---

## Architecture Summary

LimitOrderHook is a Uniswap V4 `afterSwap` hook. Users deposit tokens and specify a trigger price. When a subsequent swap moves the pool price past the trigger, the hook automatically executes a counter-swap on behalf of the user and sends them the output tokens minus a fee.

**Key mechanisms:**

1. **Tick Buckets:** Orders are mapped to Uniswap tick-space buckets via `tickToOrders[alignedTick]`. A sorted doubly-linked list (`nextActiveTick` / `prevActiveTick`) with sentinel boundaries enables O(K) scanning of only populated ticks.

2. **afterSwap Execution:** The hook reads the post-swap tick, walks the linked list in the appropriate direction, and executes eligible orders via internal `PoolManager.swap()` calls using flash accounting (`settle` / `take`).

3. **Graceful Execution:** `_executeOrder` returns `bool` instead of reverting. Failed orders emit `OrderExecutionFailed` and remain for retry. This prevents a single toxic order from DoS-ing all pool swaps.

4. **Gas Metering:** A `gasleft() < 150_000` check stops batch execution before out-of-gas, preserving remaining orders for the next swap.

5. **Fee Mechanism:** Configurable fee (default 5 BPS, max 50 BPS) deducted from `amountOut`. Accumulated per-currency in `pendingFees`, withdrawable by owner.

---

## Areas of Concern for Auditors

### High Priority

1. **Flash Accounting Correctness:** The `_executeOrder` function performs an internal swap via `poolManager.swap()` and then settles/takes within the same `afterSwap` callback. Verify that the `settle` and `take` calls correctly handle all token flows and that no tokens can be lost or double-counted.

2. **Linked List Integrity:** Verify that `_insertActiveTick` and `_removeActiveTick` maintain list invariants under all code paths (concurrent insertions at the same tick, removal of last order in a bucket, interactions between `createLimitOrder`, `cancelOrder`, `forceCancelOrder`, and `_executeOrder`).

3. **Reentrancy Surface:** `afterSwap` is called by PoolManager during an `unlock` callback. The hook then performs its own `poolManager.swap()` internally. Verify that the reentrancy guard placement is correct and that no re-entrant path can corrupt state.

4. **Slippage Validation:** `_executeOrder` validates `amountOut` against the order's `triggerPrice` with a 0.5% tolerance (`MAX_SLIPPAGE_BPS = 50`). Verify this check is correct for both `zeroForOne` directions and that manipulation of the intermediate swap cannot bypass it.

### Medium Priority

5. **MEV Extraction:** Consider whether a searcher can sandwich the `afterSwap` execution to extract value from limit order fills. The hook executes swaps at market price within the same transaction — evaluate the economic impact.

6. **Fee Accounting:** Verify that `feeBps` changes via `setFeeBps` do not affect in-flight order executions and that `pendingFees` cannot overflow or underflow.

7. **Gas Metering Edge Cases:** The 150k gas threshold is a heuristic. Evaluate whether an attacker can craft orders that consume exactly enough gas to pass the check but revert inside the swap.

8. **Order Cleanup:** When `_executeOrder` fills an order, it is removed from `tickToOrders` via swap-and-pop. Verify that removal during iteration (batch execution loop) does not skip or double-process orders.

### Low Priority

9. **Integer Precision:** `sqrtPriceToUint128` and `uint128ToSqrtPrice` perform price conversions with potential precision loss. Evaluate whether rounding errors can be exploited.

10. **Admin Functions:** `forceCancelOrder` can cancel any active order. This is intended for cleanup of stuck orders. Verify it cannot be used to grief users (owner is a 2-of-3 multisig in production).

---

## Known Issues & Accepted Risks

| # | Description | Rationale |
|---|-------------|-----------|
| K-1 | **Owner is an EOA during deployment, then transferred to Gnosis Safe.** There is a window between deployment and ownership transfer where a single key controls the contract. | Deployment and transfer happen in the same session. On mainnet, both chains already have Safe ownership. |
| K-2 | **Reliance on Uniswap V4 PoolManager security.** The hook trusts that `PoolManager.swap()`, `settle()`, and `take()` behave correctly. | PoolManager is a core Uniswap V4 contract audited by multiple firms. This is an intentional trust assumption. |
| K-3 | **No oracle for trigger price validation.** Trigger prices are set by users and validated only against the swap output. A user can set an unrealistic trigger price; the order simply will not fill. | This is by design — the hook is non-custodial and does not enforce price reasonableness. |
| K-4 | **Linked list walk is O(N) for insertion.** `_insertActiveTick` walks from `SENTINEL_MIN` to find the sorted position. With many active ticks, this becomes expensive. | Acceptable for the expected scale (dozens to low hundreds of active ticks). A hint parameter could optimize this if needed. |
| K-5 | **`isExecuting` flag is not reentrancy-safe in the traditional sense.** It is a boolean flag, not a mutex. It prevents recursive `afterSwap` calls from re-entering execution, but relies on PoolManager calling `afterSwap` synchronously. | This matches the Uniswap V4 hook execution model. `afterSwap` is called within `unlock`, which is synchronous. |
| K-6 | **No partial fills.** Orders execute fully or not at all (subject to available liquidity in the pool). | By design. Partial fill support adds significant complexity and is out of scope for v1. |

---

## Test Suite

| Category | Count | Description |
|----------|-------|-------------|
| Unit tests | 5 | Core order CRUD, price conversion |
| Integration tests | 33 | Full lifecycle with PoolManager, linked list operations, batch execution, fee verification, edge cases |
| **Total** | **38** | All passing (CI green) |

Run tests:
```bash
forge test -vv
```

---

## Deployment Verification

Both mainnet deployments are source-verified:

- **Base:** [BaseScan](https://basescan.org/address/0x45d971BdE51dd5E109036aB70a4E0b0eD2Dc4040#code)
- **Unichain:** Verified via Etherscan V2 API (`chainid=130`)

E2E order execution confirmed on both chains: Base (order #0) and Unichain (orders #0, #1), all `isFilled = true`.

---

## Contact

- **GitHub:** [@impetus82](https://github.com/impetus82)
- **Telegram:** @yurka_e
- **Email:** egoshin_crypto@proton.me