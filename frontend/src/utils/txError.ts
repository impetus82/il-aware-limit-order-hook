/**
 * Extract a short, human-readable message from a wagmi/viem error.
 * Shared by CreateOrderForm and OrderList so tx-error copy stays consistent.
 */
export function extractTxError(err: { message?: string } | null | undefined): string {
  const msg = err?.message ?? "";
  if (!msg) return "Unknown error";

  if (/user rejected|rejected the request|user denied|denied transaction/i.test(msg)) {
    return "Transaction rejected in wallet";
  }
  if (/insufficient funds/i.test(msg)) {
    return "Insufficient ETH for gas fees";
  }
  if (/revert/i.test(msg)) {
    const m = msg.match(/reason:\s*(.+?)(?:\n|$)/i) || msg.match(/reverted with[^:]*:\s*(.+?)(?:\n|$)/i);
    return m ? `Reverted: ${m[1].trim()}` : "Transaction reverted by contract";
  }
  return msg.length > 120 ? msg.slice(0, 120) + "…" : msg;
}
