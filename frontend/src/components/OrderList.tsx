"use client";

import { useEffect } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useIsFetching } from "@tanstack/react-query";
import { formatUnits, type Address } from "viem";
import {
  getChainContracts,
  getSortedTokens,
  HOOK_ABI,
  POOL_FEE,
  TICK_SPACING,
  VAULT_APY_LABEL,
} from "@/config/contracts";
import { getTriggerPriceConfig } from "@/utils/price";
import { extractTxError } from "@/utils/txError";

// ── Types ────────────────────────────────────────────────
// Matches ILAwareLimitOrderHook.LimitOrder struct (no creator — ERC721 owns it)
interface OrderData {
  amount0: bigint;
  amount1: bigint;
  token0: Address;
  token1: Address;
  triggerPrice: bigint;
  createdAt: bigint;
  isFilled: boolean;
  zeroForOne: boolean;
  vaultShares: bigint;
  sqrtPriceAtFill: bigint;
}

type OrderStatus = "active" | "filled" | "claimed" | "cancelled";

// ── OrderList (parent) ──────────────────────────────────
export default function OrderList({
  refetchKey,
  onRefresh,
}: {
  /** Increment to trigger refetch after create/cancel */
  refetchKey: number;
  /** Force-refresh all on-chain reads (passed from the page) */
  onRefresh?: () => void;
}) {
  const { address } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);
  const fetchingCount = useIsFetching();

  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

  const {
    data: orderIds,
    isLoading,
    refetch: refetchIds,
  } = useReadContract({
    ...hookContract,
    functionName: "getUserOrders",
    args: address ? [address] : undefined,
    query: {
      enabled: !!address,
      refetchInterval: 12_000,
    },
  });

  useEffect(() => {
    if (address) refetchIds();
  }, [refetchKey, address, refetchIds]);

  if (!address) return null;

  const ids = (orderIds as bigint[] | undefined) ?? [];

  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
      <div className="flex items-center justify-between mb-5">
        <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider">
          Your Orders
        </h3>
        {onRefresh && (
          <button
            onClick={onRefresh}
            aria-label="Refresh orders"
            title="Refresh orders"
            className="inline-flex items-center gap-1.5 text-xs text-gray-500 hover:text-gray-300 transition-colors"
          >
            <svg
              aria-hidden="true"
              className={`h-3.5 w-3.5 ${fetchingCount > 0 ? "animate-spin" : ""}`}
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
            >
              <path d="M21 12a9 9 0 11-2.64-6.36M21 3v6h-6" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            {fetchingCount > 0 ? "Updating…" : "Refresh"}
          </button>
        )}
      </div>

      {isLoading ? (
        <div className="space-y-3">
          {[1, 2].map((i) => (
            <div
              key={i}
              className="h-24 rounded-lg bg-gray-800 animate-pulse"
            />
          ))}
        </div>
      ) : ids.length === 0 ? (
        <p className="text-sm text-gray-500 text-center py-6">
          No orders yet. Place your first limit order above.
        </p>
      ) : (
        <div className="space-y-3">
          {ids.map((id) => (
            <OrderItem
              key={id.toString()}
              orderId={id}
              chainId={chainId}
              connectedAddress={address}
              refetchKey={refetchKey}
              onActionCompleted={() => refetchIds()}
            />
          ))}
        </div>
      )}
    </div>
  );
}

// ── OrderItem (child) ───────────────────────────────────
function OrderItem({
  orderId,
  chainId,
  connectedAddress,
  refetchKey,
  onActionCompleted,
}: {
  orderId: bigint;
  chainId: number;
  connectedAddress: Address;
  refetchKey: number;
  onActionCompleted: () => void;
}) {
  const chain = getChainContracts(chainId);
  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;
  const triggerPriceConfig = getTriggerPriceConfig(chain.wethIsCurrency0);
  const tokens = getSortedTokens(chainId);

  // Build poolKey tuple for claimOrder
  const poolKey = {
    currency0: tokens.currency0.address as Address,
    currency1: tokens.currency1.address as Address,
    fee: POOL_FEE,
    tickSpacing: TICK_SPACING,
    hooks: chain.hook,
  };

  // ── Read: order data ──────────────────────────────────
  const {
    data: orderRaw,
    isLoading,
    refetch: refetchOrder,
  } = useReadContract({
    ...hookContract,
    functionName: "getOrder",
    args: [orderId],
    query: { refetchInterval: 12_000, retry: false },
  });

  // ── Read: ERC721 ownerOf — reverts if NFT is burned ──
  // isError=true means the order NFT was burned (cancelled or claimed).
  // retry:false → expected reverts don't spam RPC/console.
  const {
    data: ownerOfData,
    isError: ownerOfError,
    refetch: refetchOwner,
  } = useReadContract({
    ...hookContract,
    functionName: "ownerOf",
    args: [orderId],
    query: { refetchInterval: 12_000, retry: false },
  });

  const isOwner =
    ownerOfData !== undefined &&
    (ownerOfData as Address).toLowerCase() ===
      connectedAddress.toLowerCase();

  // ── Writes ────────────────────────────────────────────
  const {
    data: cancelHash,
    writeContract: writeCancelOrder,
    isPending: cancelPending,
    error: cancelWriteError,
  } = useWriteContract();
  const {
    isSuccess: cancelConfirmed,
    isLoading: cancelWaiting,
    error: cancelReceiptError,
  } = useWaitForTransactionReceipt({ hash: cancelHash });

  const {
    data: depositHash,
    writeContract: writeDepositToVault,
    isPending: depositPending,
    error: depositWriteError,
  } = useWriteContract();
  const {
    isSuccess: depositConfirmed,
    isLoading: depositWaiting,
    error: depositReceiptError,
  } = useWaitForTransactionReceipt({ hash: depositHash });

  const {
    data: claimHash,
    writeContract: writeClaimOrder,
    isPending: claimPending,
    error: claimWriteError,
  } = useWriteContract();
  const {
    isSuccess: claimConfirmed,
    isLoading: claimWaiting,
    error: claimReceiptError,
  } = useWaitForTransactionReceipt({ hash: claimHash });

  // Refetch BOTH getOrder and ownerOf after any confirmed action so the status
  // badge / buttons update immediately instead of lagging the 12s poll.
  useEffect(() => {
    if (cancelConfirmed || depositConfirmed || claimConfirmed) {
      Promise.all([refetchOrder(), refetchOwner()]).then(() => onActionCompleted());
    }
  }, [cancelConfirmed, depositConfirmed, claimConfirmed, refetchOrder, refetchOwner, onActionCompleted]);

  useEffect(() => {
    refetchOrder();
  }, [refetchKey, refetchOrder]);

  if (isLoading) {
    return <div className="h-24 rounded-lg bg-gray-800 animate-pulse" />;
  }

  const order = orderRaw as OrderData | undefined;
  if (!order) return null;

  // ownerOf reverts when the NFT is burned. cancelOrder only burns UNFILLED
  // orders; claimOrder only burns FILLED ones — so isFilled distinguishes them.
  const status: OrderStatus = ownerOfError
    ? order.isFilled
      ? "claimed"
      : "cancelled"
    : order.isFilled
      ? "filled"
      : "active";

  const isTerminal = status === "claimed" || status === "cancelled";

  // ── In-flight + error state ───────────────────────────
  const cancelInFlight = cancelPending || (!!cancelHash && cancelWaiting);
  const depositInFlight = depositPending || (!!depositHash && depositWaiting);
  const claimInFlight = claimPending || (!!claimHash && claimWaiting);
  const busy = cancelInFlight || depositInFlight || claimInFlight;

  const actionErr =
    cancelWriteError ||
    cancelReceiptError ||
    depositWriteError ||
    depositReceiptError ||
    claimWriteError ||
    claimReceiptError;
  const actionError = actionErr ? extractTxError(actionErr) : null;

  // ── Direction & amounts ───────────────────────────────
  const isSellWeth = chain.wethIsCurrency0
    ? order.zeroForOne
    : !order.zeroForOne;

  const directionLabel = isSellWeth
    ? `Sell ${chain.weth.symbol} → ${chain.usdc.symbol}`
    : `Buy ${chain.weth.symbol} ← ${chain.usdc.symbol}`;

  const inputToken = isSellWeth ? chain.weth : chain.usdc;
  const outputToken = isSellWeth ? chain.usdc : chain.weth;

  const displayInputAmount = chain.wethIsCurrency0
    ? isSellWeth
      ? order.amount0
      : order.amount1
    : isSellWeth
      ? order.amount1
      : order.amount0;
  const displayOutputAmount = chain.wethIsCurrency0
    ? isSellWeth
      ? order.amount1
      : order.amount0
    : isSellWeth
      ? order.amount0
      : order.amount1;

  // ── Trigger price display ─────────────────────────────
  let triggerDisplay: number;
  if (triggerPriceConfig.needsInversion) {
    const storedNum =
      Number(order.triggerPrice) / 10 ** triggerPriceConfig.decimals;
    triggerDisplay = storedNum > 0 ? 1 / storedNum : 0;
  } else {
    triggerDisplay =
      Number(order.triggerPrice) / 10 ** triggerPriceConfig.decimals;
  }

  const hasVaultDeposit = order.vaultShares > 0n;

  // ── Handlers ─────────────────────────────────────────
  const handleCancel = () =>
    writeCancelOrder({ ...hookContract, functionName: "cancelOrder", args: [orderId] });
  const handleDepositToVault = () =>
    writeDepositToVault({ ...hookContract, functionName: "depositToVault", args: [orderId] });
  const handleClaim = () =>
    writeClaimOrder({ ...hookContract, functionName: "claimOrder", args: [orderId, poolKey] });

  const explorerName = chain.chainLabel === "BASE" ? "BaseScan" : "Uniscan";
  const pendingHash = cancelHash ?? depositHash ?? claimHash;

  return (
    <div
      className={`rounded-lg border p-4 ${
        isTerminal
          ? "border-gray-800 bg-gray-900/40"
          : "border-gray-700 bg-gray-800/50"
      }`}
    >
      {/* Header row */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2 min-w-0">
          <span
            className="text-xs text-gray-500 font-mono"
            title={`This limit order is ERC-721 NFT #${orderId.toString()} — transferable & composable`}
          >
            NFT #{orderId.toString()}
          </span>
          <StatusBadge status={status} />
          {hasVaultDeposit && status === "filled" && (
            <span
              className="text-[11px] bg-purple-900/40 text-purple-400 border border-purple-800/50 px-2 py-0.5 rounded-full"
              title={`Output is in the vault (${VAULT_APY_LABEL})`}
            >
              In Vault
            </span>
          )}
        </div>
        <span className="text-xs text-gray-500 shrink-0">{directionLabel}</span>
      </div>

      {/* Terminal states get a compact summary instead of zeroed amounts */}
      {status === "claimed" ? (
        <div className="rounded-lg bg-emerald-500/10 border border-emerald-500/30 px-3 py-2">
          <p className="text-sm text-emerald-400 font-medium">Claimed ✓</p>
          <p className="text-xs text-emerald-500/70 mt-0.5">
            Output{hasVaultDeposit ? " + IL rebate" : ""} sent to your wallet. NFT burned.
          </p>
        </div>
      ) : status === "cancelled" ? (
        <p className="text-xs text-gray-500">Cancelled — input refunded, NFT burned.</p>
      ) : (
        <>
          {/* Details */}
          <div className="grid grid-cols-2 gap-y-2 text-sm">
            <span className="text-gray-500">Input</span>
            <span className="text-right text-white font-mono">
              {formatUnits(displayInputAmount, inputToken.decimals)}{" "}
              {inputToken.symbol}
            </span>

            {status === "filled" && displayOutputAmount > 0n && (
              <>
                <span className="text-gray-500">Output</span>
                <span className="text-right text-emerald-400 font-mono">
                  {formatUnits(displayOutputAmount, outputToken.decimals)}{" "}
                  {outputToken.symbol}
                </span>
              </>
            )}

            <span className="text-gray-500">Trigger</span>
            <span className="text-right text-gray-300 font-mono">
              {triggerDisplay.toFixed(2)} USDC/WETH
            </span>
          </div>

          {/* Action error */}
          {actionError && (
            <div className="mt-3 p-2 rounded-lg bg-red-500/10 border border-red-500/30">
              <p className="text-xs text-red-400">{actionError}</p>
            </div>
          )}

          {/* Action area — only for the current NFT owner */}
          {isOwner && (
            <div className="mt-3 flex flex-col gap-2">
              {/* Active: Cancel + ghost hint that vault unlocks on fill */}
              {status === "active" && (
                <>
                  <button
                    onClick={handleCancel}
                    disabled={busy}
                    className="w-full rounded-lg bg-red-900/30 border border-red-800/50 py-2 text-sm text-red-400 hover:bg-red-900/50 transition-colors disabled:opacity-50"
                  >
                    {cancelInFlight ? "Cancelling…" : "Cancel Order"}
                  </button>
                  <div
                    className="w-full rounded-lg border border-dashed border-gray-700 py-2 text-center text-xs text-gray-600"
                    title="Once a swap crosses your trigger, the order fills and the vault deposit unlocks"
                  >
                    Deposit to Vault — unlocks after fill
                  </div>
                </>
              )}

              {/* Filled + no vault deposit yet: optional Deposit (honest copy) */}
              {status === "filled" && !hasVaultDeposit && (
                <div className="flex flex-col gap-1">
                  <button
                    onClick={handleDepositToVault}
                    disabled={busy}
                    className="w-full rounded-lg bg-purple-900/30 border border-purple-800/50 py-2 text-sm text-purple-300 hover:bg-purple-900/50 transition-colors disabled:opacity-50"
                  >
                    {depositInFlight ? "Depositing…" : "Deposit to Vault (earn yield)"}
                  </button>
                  <p className="text-[11px] text-gray-600 text-center">
                    Demo vault — {VAULT_APY_LABEL}, not real lending.
                  </p>
                </div>
              )}

              {/* Filled: Claim (with or without rebate) */}
              {status === "filled" && (
                <button
                  onClick={handleClaim}
                  disabled={busy}
                  className="w-full rounded-lg bg-emerald-900/30 border border-emerald-800/50 py-2 text-sm text-emerald-400 hover:bg-emerald-900/50 transition-colors disabled:opacity-50"
                >
                  {claimInFlight
                    ? "Claiming…"
                    : hasVaultDeposit
                      ? "Claim Order + IL Rebate"
                      : "Claim Order"}
                </button>
              )}
            </div>
          )}
        </>
      )}

      {/* Tx explorer link */}
      {pendingHash && (
        <p className="text-xs text-gray-500 text-center mt-2">
          <a
            href={`${chain.explorerUrl}/tx/${pendingHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400/70 hover:text-blue-400 underline"
          >
            View on {explorerName} ↗
          </a>
        </p>
      )}
    </div>
  );
}

// ── StatusBadge ─────────────────────────────────────────
function StatusBadge({ status }: { status: OrderStatus }) {
  const styles: Record<OrderStatus, string> = {
    active: "bg-blue-900/40 text-blue-400 border-blue-800/50",
    filled: "bg-emerald-900/40 text-emerald-400 border-emerald-800/50",
    claimed: "bg-emerald-900/40 text-emerald-300 border-emerald-700/60",
    cancelled: "bg-gray-800 text-gray-500 border-gray-700",
  };

  return (
    <span
      className={`text-[11px] font-medium px-2 py-0.5 rounded-full border ${styles[status]}`}
    >
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </span>
  );
}
