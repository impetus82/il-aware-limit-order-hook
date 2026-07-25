# ILAwareLimitOrderHook — Integration Guide

How to place, read, and settle IL-aware limit orders programmatically, without reading the
contract source. A typed viem-based SDK lives in [`sdk/`](../sdk/) and wraps every footgun
described below; the raw-call reference is included for integrators who prefer direct calls.

---

## 1. Deployments

| | Base (8453) | Unichain (130) |
|---|---|---|
| **Hook** | [`0x1afeB37bdC763c1FC8CCB4E30c39BFFe139894Ce`](https://basescan.org/address/0x1afeb37bdc763c1fc8ccb4e30c39bffe139894ce) | [`0x8C19f1641946c662308000bB4E2Eaf684c81d4CE`](https://uniscan.xyz/address/0x8C19f1641946c662308000bB4E2Eaf684c81d4CE) |
| PoolManager (v4) | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x1F98400000000000000000000000000000000004` |
| StateView | `0xa3c0c9b65bad0b08107aa264b0f3db444b867a71` | `0x86e8631a016f9068c3f085faf484ee3f5fdee8f2` |
| WETH | `0x4200000000000000000000000000000000000006` (18 dec) | `0x4200000000000000000000000000000000000006` (18 dec) |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 dec) | `0x078D782b760474a361dDA0AF3839290b0EF57AD6` (6 dec) |
| WETH/USDC pool (fee 3000, spacing 60) | `0x8d27ee1ba3ae15df876ab2929cc21e23109ba2e3f181222eb795466956727c08` | `0xe1d695d4c147091549aeb6f9e78521a0184a1e7e272a71c12e708c881981f6ba` |
| **currency0** | **WETH** | **USDC** |
| Yield vault (`yieldVault`, immutable) | **Real Aave** — waBasUSDC `0xC768c589647798a6EE01A91FdE98EF2ed046DBD6` (ERC-4626, `asset()==USDC`) | `SimulatedYieldVault` `0xceee912C708516624E9aC5581c8FCC93eA8eE79d` — **demo, simulated 3% APY**, not real lending |

> The SDK's per-chain config is locked to these pools by test: `keccak256(abi.encode(poolKey))`
> must reproduce the on-chain poolIds above (`sdk/test/sdk.test.ts`).

## 2. Order lifecycle

```
createLimitOrder ──► resting (ERC-721 minted to you)
   │ cancelOrder ──► input refunded, NFT burned            [terminal]
   ▼ a swap crosses your trigger (hook self-executes in afterSwap — no keepers)
filled (output custodied by the hook)
   │ depositToVault (optional) ──► output earns vault yield
   ▼ claimOrder ──► output [+ rebate = min(vault yield, IL)] paid out, NFT burned  [terminal]
```

- Orders are **ERC-721** — transferable/composable; every action is gated on `ownerOf(orderId)`.
- Fills are **trigger-or-better** within a hard ±0.5% price gate; oversized orders fill partially
  at that bound and refund the unused input (the remainder is not re-queued).
- A `feeBps` execution fee (default 5 = 0.05%, max 50) is skimmed from output on fill.
- On **Base**, the vault path deposits the order's **USDC output** into real Aave; WETH-output
  orders simply skip the vault (still fully functional). On **Unichain** the vault is a demo.

## 3. Quickstart (SDK, viem)

```ts
import { createWalletClient, createPublicClient, http, erc20Abi } from "viem";
import { base } from "viem/chains";
import {
  createLimitOrderParams, claimOrderParams, depositToVaultParams, cancelOrderParams,
  readOrder, readUserOrderIds, readOrderOwner, deriveOrderStatus, getDeployment,
} from "il-aware-hook-sdk"; // in-repo package: sdk/

const chainId = 8453;
const d = getDeployment(chainId);
const pub = createPublicClient({ chain: base, transport: http() });
// const wallet = createWalletClient({ account, chain: base, transport: http() });

// 0) Approve the hook to pull your SELL token (here: sell 0.05 WETH → USDC at 1900+)
await wallet.writeContract({
  address: d.weth.address, abi: erc20Abi, functionName: "approve",
  args: [d.hook, 50_000_000_000_000_000n],
});

// 1) Place the order — direction, decimals, PoolKey, and trigger encoding are handled for you
const create = createLimitOrderParams({
  chainId, sell: "WETH", amountIn: "0.05", triggerPriceUsdcPerWeth: 1900,
});
// simulate first: `result` is the new orderId; then send the prepared request
const { request, result: newOrderId } = await pub.simulateContract({ ...create, account: wallet.account });
const txHash = await wallet.writeContract(request);

// 2) Poll status
const order = await readOrder(pub, chainId, 1n);
const owner = await readOrderOwner(pub, chainId, 1n);
console.log(deriveOrderStatus(order, owner)); // "active" | "filled" | "claimed" | "cancelled"

// 3) Once filled: optionally park output in the vault, then claim (PoolKey auto-supplied)
await wallet.writeContract(depositToVaultParams(chainId, 1n));
await wallet.writeContract(claimOrderParams(chainId, 1n));
```

## 4. Raw-call reference (no SDK)

```solidity
function createLimitOrder(PoolKey poolKey, bool zeroForOne, uint96 amountIn, uint128 triggerPrice)
    external returns (uint256 orderId);
function cancelOrder(uint256 orderId) external;                       // unfilled only, owner only
function depositToVault(uint256 orderId) external;                    // filled only, owner only
function claimOrder(uint256 orderId, PoolKey poolKey) external;       // filled only, owner only
function getOrder(uint256 orderId) external view returns (LimitOrder);
function getUserOrders(address user) external view returns (uint256[]); // append-only, creator-keyed
function ownerOf(uint256 orderId) external view returns (address);    // reverts once burned
```

`PoolKey` = `(currency0, currency1, fee=3000, tickSpacing=60, hooks=<hook>)` with currencies in
**address sort order** (see §1 — WETH first on Base, USDC first on Unichain).

### Trigger-price encoding (the #1 footgun)

The hook stores `triggerPrice` as the **raw pool price (currency1 per currency0) scaled to 1e18**
and compares in that same orientation. For a human "USDC per WETH" price `P`:

| Chain | currency0 | stored value | encoding |
|---|---|---|---|
| Base | WETH | `P` | `parseUnits(P, 6)` — e.g. 1900 → `1_900_000_000` |
| Unichain | USDC | `1/P` | `parseUnits((1/P).toFixed(24), 30)` |

Bounds enforced by the hook: `0 < triggerPrice ≤ 1e36` (`InvalidTriggerPrice`), `amountIn ≤ uint96`.

### Eligibility semantics

`zeroForOne = true` sells currency0 (a **SELL** relative to the pool): triggers when the pool
price rises to `price ≥ trigger`. `zeroForOne = false` buys currency0: triggers at `price ≤ trigger`.
The SDK derives this from "which token you sell", so WETH-sellers get rising-price triggers on
both chains despite the flipped sort order.

## 5. Events

| Event | When |
|---|---|
| `OrderCreated(orderId, creator, zeroForOne, amountIn, triggerPrice)` | order placed |
| `OrderFilled(orderId, creator, amountIn, amountOut, executionPrice)` | fill (full or partial-at-gate) |
| `OrderCancelled(orderId, creator)` / `OrderForceCancelled(orderId, admin)` | cancel paths |
| `OrderExecutionFailed(orderId, reason)` | graceful skip — order stays resting, swap unaffected |
| `Transfer(from, to, orderId)` (ERC-721) | mint / transfer / burn of the order NFT |
| `FeeCollected(orderId, currency, feeAmount)` | execution fee credited on fill |
| `YieldSurplusToFees(orderId, currency, amount)` | un-rebated vault yield captured on claim |
| `VaultRedeemFailed(orderId, shares)` | vault redeem reverted — position stays intact, re-claim later |

## 6. Integrator notes & caveats

- **`getUserOrders` is creator-keyed and append-only** — it does not follow ERC-721 transfers.
  To track transferred-in orders, index `Transfer` events or track ids explicitly.
- **Approve before create:** the hook pulls the sell token via `transferFrom`.
- **Fills need pool liquidity + swap flow** — the hook executes inside other users' swaps.
- **Reads:** `getOrder` on a never-minted id returns an all-zero struct (no revert);
  `ownerOf` reverts once the NFT is burned — treat that as claimed/cancelled (see §3).
- Security posture, invariants, and accepted risks: [`docs/AUDIT_SCOPE.md`](AUDIT_SCOPE.md) +
  [`docs/THREAT_MODEL.md`](THREAT_MODEL.md).
