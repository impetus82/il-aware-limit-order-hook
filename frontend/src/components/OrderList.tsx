"use client";

import { useEffect } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatUnits, type Address } from "viem";
import {
  getChainContracts,
  getSortedTokens,
  HOOK_ABI,
  POOL_FEE,
  TICK_SPACING,
} from "@/config/contracts";
import { getTriggerPriceConfig } from "@/utils/price";

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

type OrderStatus = "active" | "filled" | "cancelled";

// ── OrderList (parent) ──────────────────────────────────
export default function OrderList({
  refetchKey,
}: {
  /** Increment to trigger refetch after create/cancel */
  refetchKey: number;
}) {
  const { address } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);

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
      <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-5">
        Your Orders
      </h3>

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
        <p className="text-sm text-gray-600 text-center py-6">
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
    query: { refetchInterval: 12_000 },
  });

  useEffect(() => {
    refetchOrder();
  }, [refetchKey, refetchOrder]);

  // ── Read: ERC721 ownerOf — reverts if NFT is burned ──
  // isError=true means the order NFT was burned (cancelled or claimed)
  const { data: ownerOfData, isError: ownerOfError } = useReadContract({
    ...hookContract,
    functionName: "ownerOf",
    args: [orderId],
    query: { refetchInterval: 12_000 },
  });

  const isOwner =
    ownerOfData !== undefined &&
    (ownerOfData as Address).toLowerCase() ===
      connectedAddress.toLowerCase();

  // ── Write: cancelOrder ────────────────────────────────
  const { data: cancelHash, writeContract: writeCancelOrder } =
    useWriteContract();
  const { isSuccess: cancelConfirmed } = useWaitForTransactionReceipt({
    hash: cancelHash,
  });

  // ── Write: depositToVault ─────────────────────────────
  const { data: depositHash, writeContract: writeDepositToVault } =
    useWriteContract();
  const { isSuccess: depositConfirmed } = useWaitForTransactionReceipt({
    hash: depositHash,
  });

  // ── Write: claimOrder ─────────────────────────────────
  const { data: claimHash, writeContract: writeClaimOrder } =
    useWriteContract();
  const { isSuccess: claimConfirmed } = useWaitForTransactionReceipt({
    hash: claimHash,
  });

  // Refetch after any confirmed action
  useEffect(() => {
    if (cancelConfirmed || depositConfirmed || claimConfirmed) {
      refetchOrder().then(() => onActionCompleted());
    }
  }, [cancelConfirmed, depositConfirmed, claimConfirmed, refetchOrder, onActionCompleted]);

  if (isLoading) {
    return <div className="h-24 rounded-lg bg-gray-800 animate-pulse" />;
  }

  const order = orderRaw as OrderData | undefined;
  if (!order) return null;

  // ownerOf reverts when NFT is burned (cancelled or claimed)
  const status: OrderStatus = ownerOfError
    ? "cancelled"
    : order.isFilled
      ? "filled"
      : "active";

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

  // ── Vault status ──────────────────────────────────────
  const hasVaultDeposit = order.vaultShares > 0n;

  // ── Handlers ─────────────────────────────────────────
  const handleCancel = () => {
    writeCancelOrder({
      ...hookContract,
      functionName: "cancelOrder",
      args: [orderId],
    });
  };

  const handleDepositToVault = () => {
    writeDepositToVault({
      ...hookContract,
      functionName: "depositToVault",
      args: [orderId],
    });
  };

  const handleClaim = () => {
    writeClaimOrder({
      ...hookContract,
      functionName: "claimOrder",
      args: [orderId, poolKey],
    });
  };

  const explorerName = chain.chainLabel === "BASE" ? "BaseScan" : "Uniscan";
  const pendingHash = cancelHash ?? depositHash ?? claimHash;

  return (
    <div className="rounded-lg border border-gray-700 bg-gray-800/50 p-4">
      {/* Header row */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <span className="text-xs text-gray-500 font-mono">
            #{orderId.toString()}
          </span>
          <StatusBadge status={status} />
          {hasVaultDeposit && status === "filled" && (
            <span className="text-[11px] bg-purple-900/40 text-purple-400 border border-purple-800/50 px-2 py-0.5 rounded-full">
              In Vault
            </span>
          )}
        </div>
        <span className="text-xs text-gray-500">{directionLabel}</span>
      </div>

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

      {/* Action buttons — only for the current NFT owner */}
      {isOwner && (
        <div className="mt-3 flex flex-col gap-2">
          {/* Active: Cancel */}
          {status === "active" && (
            <button
              onClick={handleCancel}
              disabled={!!cancelHash && !cancelConfirmed}
              className="w-full rounded-lg bg-red-900/30 border border-red-800/50 py-2 text-sm text-red-400 hover:bg-red-900/50 transition-colors disabled:opacity-50"
            >
              {cancelHash && !cancelConfirmed ? "Cancelling…" : "Cancel Order"}
            </button>
          )}

          {/* Filled + no vault deposit: Deposit to Vault (optional) */}
          {status === "filled" && !hasVaultDeposit && (
            <button
              onClick={handleDepositToVault}
              disabled={!!depositHash && !depositConfirmed}
              className="w-full rounded-lg bg-purple-900/30 border border-purple-800/50 py-2 text-sm text-purple-300 hover:bg-purple-900/50 transition-colors disabled:opacity-50"
            >
              {depositHash && !depositConfirmed
                ? "Depositing…"
                : "Deposit to Vault (earn yield)"}
            </button>
          )}

          {/* Filled: Claim Order (with or without vault yield rebate) */}
          {status === "filled" && (
            <button
              onClick={handleClaim}
              disabled={!!claimHash && !claimConfirmed}
              className="w-full rounded-lg bg-emerald-900/30 border border-emerald-800/50 py-2 text-sm text-emerald-400 hover:bg-emerald-900/50 transition-colors disabled:opacity-50"
            >
              {claimHash && !claimConfirmed
                ? "Claiming…"
                : hasVaultDeposit
                  ? "Claim Order + IL Rebate"
                  : "Claim Order"}
            </button>
          )}
        </div>
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
