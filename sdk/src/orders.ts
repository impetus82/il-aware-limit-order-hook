/**
 * Order lifecycle: transaction-parameter builders + typed readers.
 *
 * Builders return `{ address, abi, functionName, args }` objects that spread directly into
 * viem's `writeContract` / `simulateContract` or wagmi's `useWriteContract` — the SDK does not
 * hold keys or send anything itself.
 *
 * Footguns handled here so integrators don't have to:
 *  - `claimOrder` REQUIRES the full PoolKey tuple (not just the orderId) — auto-supplied.
 *  - `zeroForOne` depends on the chain's token sort order — derived from "which token you sell".
 *  - `amountIn` is a uint96 in the token's OWN decimals (WETH 18 / USDC 6) — parsed + bounds-checked.
 *  - The user must ERC-20 `approve(hook, amountIn)` on the SELL token before createLimitOrder.
 */

import { parseUnits, type PublicClient } from "viem";
import { hookAbi } from "./abi.js";
import { buildPoolKey, getDeployment } from "./addresses.js";
import { encodeTriggerPrice, UINT96_MAX } from "./price.js";

export type SellToken = "WETH" | "USDC";

export interface CreateLimitOrderInput {
  chainId: number;
  /** Which token you are selling (the input token you must approve to the hook). */
  sell: SellToken;
  /** Human amount of the SELL token, e.g. "0.05" WETH or "150" USDC. */
  amountIn: string;
  /** Human trigger price, always quoted as USDC per WETH (e.g. 1900 or "1900"). */
  triggerPriceUsdcPerWeth: number | string;
}

/** Params for `createLimitOrder(poolKey, zeroForOne, amountIn, triggerPrice)`. */
export function createLimitOrderParams(input: CreateLimitOrderInput) {
  const d = getDeployment(input.chainId);
  const sellToken = input.sell === "WETH" ? d.weth : d.usdc;

  const amountIn = parseUnits(input.amountIn, sellToken.decimals);
  if (amountIn <= 0n) throw new Error(`amountIn must be positive, got ${input.amountIn}`);
  if (amountIn > UINT96_MAX) {
    throw new Error(`amountIn ${amountIn} exceeds uint96 max — the hook stores amounts as uint96`);
  }

  // zeroForOne = "selling currency0 for currency1". WETH is currency0 on Base but currency1 on Unichain.
  const zeroForOne = input.sell === "WETH" ? d.wethIsCurrency0 : !d.wethIsCurrency0;

  return {
    address: d.hook,
    abi: hookAbi,
    functionName: "createLimitOrder",
    args: [buildPoolKey(input.chainId), zeroForOne, amountIn, encodeTriggerPrice(input.chainId, input.triggerPriceUsdcPerWeth)],
  } as const;
}

/** Params for `claimOrder(orderId, poolKey)` — the required PoolKey tuple is filled in for you. */
export function claimOrderParams(chainId: number, orderId: bigint) {
  return {
    address: getDeployment(chainId).hook,
    abi: hookAbi,
    functionName: "claimOrder",
    args: [orderId, buildPoolKey(chainId)],
  } as const;
}

/** Params for `depositToVault(orderId)` — only valid for FILLED orders; owner-only. */
export function depositToVaultParams(chainId: number, orderId: bigint) {
  return {
    address: getDeployment(chainId).hook,
    abi: hookAbi,
    functionName: "depositToVault",
    args: [orderId],
  } as const;
}

/** Params for `cancelOrder(orderId)` — only valid for UNFILLED orders; owner-only. */
export function cancelOrderParams(chainId: number, orderId: bigint) {
  return {
    address: getDeployment(chainId).hook,
    abi: hookAbi,
    functionName: "cancelOrder",
    args: [orderId],
  } as const;
}

// ── Readers ────────────────────────────────────────────────────────────────

export interface LimitOrder {
  amount0: bigint;
  amount1: bigint;
  token0: `0x${string}`;
  token1: `0x${string}`;
  triggerPrice: bigint;
  createdAt: bigint;
  isFilled: boolean;
  zeroForOne: boolean;
  vaultShares: bigint;
  sqrtPriceAtFill: bigint;
  poolId: `0x${string}`;
}

export type OrderStatus = "active" | "filled" | "claimed" | "cancelled";

/** Read a single order struct. A never-minted id returns an all-zero struct (createdAt === 0n). */
export async function readOrder(client: PublicClient, chainId: number, orderId: bigint): Promise<LimitOrder> {
  const d = getDeployment(chainId);
  return (await client.readContract({
    address: d.hook,
    abi: hookAbi,
    functionName: "getOrder",
    args: [orderId],
  })) as LimitOrder;
}

/**
 * Order ids ever CREATED by `user` (append-only; includes filled/cancelled/claimed ids).
 * NOTE: this does NOT track ERC-721 transfers — an order NFT transferred to a wallet will not
 * appear in that wallet's list. Resolve current ownership per-id via `readOrderOwner`.
 */
export async function readUserOrderIds(
  client: PublicClient,
  chainId: number,
  user: `0x${string}`,
): Promise<readonly bigint[]> {
  const d = getDeployment(chainId);
  return (await client.readContract({
    address: d.hook,
    abi: hookAbi,
    functionName: "getUserOrders",
    args: [user],
  })) as readonly bigint[];
}

/** Current NFT owner of an order, or null if the NFT is burned (order claimed or cancelled). */
export async function readOrderOwner(
  client: PublicClient,
  chainId: number,
  orderId: bigint,
): Promise<`0x${string}` | null> {
  const d = getDeployment(chainId);
  try {
    return (await client.readContract({
      address: d.hook,
      abi: hookAbi,
      functionName: "ownerOf",
      args: [orderId],
    })) as `0x${string}`;
  } catch {
    return null; // ERC721: ownerOf reverts once the NFT is burned
  }
}

/**
 * Derive the lifecycle status the same way the reference UI does:
 * burned NFT (owner === null) + isFilled distinguishes claimed vs cancelled.
 */
export function deriveOrderStatus(order: LimitOrder, owner: `0x${string}` | null): OrderStatus {
  if (owner === null) return order.isFilled ? "claimed" : "cancelled";
  return order.isFilled ? "filled" : "active";
}
