"use client";

import { useReadContract, useChainId } from "wagmi";
import {
  getChainContracts,
  STATE_VIEW_ABI,
} from "@/config/contracts";
import {
  sqrtPriceX96ToPrice,
  formatPrice,
  invertPrice,
  isExtremeTick,
} from "@/utils/price";

function PriceSkeleton() {
  return (
    <span className="inline-block w-24 h-5 bg-gray-800 rounded animate-pulse" />
  );
}

export default function PoolInfo() {
  const chainId = useChainId();
  const chain = getChainContracts(chainId);

  const {
    data: slot0,
    isLoading,
    isError,
    error,
  } = useReadContract({
    address: chain.stateView,
    abi: STATE_VIEW_ABI,
    functionName: "getSlot0",
    args: [chain.poolId],
    query: { refetchInterval: 12_000 },
  });

  // ── Loading ────────────────────────────────────────────
  if (isLoading) {
    return (
      <div className="rounded-xl border border-gray-800 bg-gray-900 p-5">
        <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
          Pool Price
        </h3>
        <div className="space-y-3">
          <div className="flex justify-between items-center">
            <span className="text-gray-400">Current Price</span>
            <PriceSkeleton />
          </div>
          <div className="flex justify-between items-center">
            <span className="text-gray-400">Current Tick</span>
            <PriceSkeleton />
          </div>
        </div>
      </div>
    );
  }

  // ── Error ──────────────────────────────────────────────
  if (isError) {
    return (
      <div className="rounded-xl border border-red-900/50 bg-red-950/30 p-5">
        <h3 className="text-sm font-medium text-red-400 uppercase tracking-wider mb-2">
          Pool Price — Error
        </h3>
        <p className="text-red-300 text-sm">
          Failed to read pool state.{" "}
          {error?.message?.includes("revert")
            ? "Pool may not be initialized or PoolId mismatch."
            : "Check RPC connection."}
        </p>
        <p className="text-red-500/60 text-xs mt-2 font-mono break-all">
          {error?.message?.slice(0, 120)}
        </p>
      </div>
    );
  }

  // ── Parse ──────────────────────────────────────────────
  const sqrtPriceX96 = slot0?.[0] as bigint | undefined;
  const tick = slot0?.[1] as number | undefined;

  // Always returns USDC per WETH regardless of chain
  const priceRaw =
    sqrtPriceX96 !== undefined
      ? sqrtPriceX96ToPrice(sqrtPriceX96, chain.wethIsCurrency0)
      : 0;

  const priceForward = formatPrice(priceRaw);
  const priceInverse = formatPrice(invertPrice(priceRaw));

  const isPoolEmpty = sqrtPriceX96 === BigInt(0);
  const extreme = tick !== undefined && isExtremeTick(tick);

  // ── Render ─────────────────────────────────────────────
  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-5">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider">
          Pool Price — WETH / USDC
        </h3>
        <span className="text-[10px] text-gray-600 font-mono">
          {chain.chainLabel} • LIVE
        </span>
      </div>

      {isPoolEmpty ? (
        <p className="text-yellow-500 text-sm">
          Pool not initialized (sqrtPriceX96 = 0).
        </p>
      ) : (
        <div className="space-y-3">
          {/* Extreme price warning */}
          {extreme && (
            <div className="rounded-lg bg-yellow-950/40 border border-yellow-800/50 px-3 py-2">
              <p className="text-yellow-400 text-xs">
                ⚠ Pool price is at an extreme tick ({tick}). A previous large
                swap likely pushed the price to the boundary. The pool may need
                a reverse swap or re-initialization to return to normal range.
              </p>
            </div>
          )}

          {/* Primary: USDC per WETH */}
          <div className="flex justify-between items-center">
            <span className="text-gray-400 text-sm">Price</span>
            <div className="text-right">
              <span className={`font-mono font-semibold ${extreme ? "text-yellow-400 text-sm sm:text-base" : "text-white text-base sm:text-lg"}`}>
                {priceForward}
              </span>
              <span className="text-gray-500 text-xs ml-1.5">USDC per WETH</span>
            </div>
          </div>

          {/* Inverse: WETH per USDC */}
          <div className="flex justify-between items-center">
            <span className="text-gray-400 text-sm">Inverse</span>
            <div className="text-right">
              <span className="text-gray-300 font-mono text-sm">
                {priceInverse}
              </span>
              <span className="text-gray-500 text-xs ml-1.5">WETH per USDC</span>
            </div>
          </div>

          {/* Tick */}
          <div className="flex justify-between items-center">
            <span className="text-gray-400 text-sm">Tick</span>
            <span
              className={`font-mono text-sm ${
                extreme ? "text-yellow-400" : "text-gray-300"
              }`}
            >
              {tick?.toString() ?? "—"}
            </span>
          </div>

          {/* Raw sqrtPriceX96 */}
          <details className="group">
            <summary className="text-[11px] text-gray-600 cursor-pointer hover:text-gray-400 transition-colors">
              Raw sqrtPriceX96 ▸
            </summary>
            <p className="text-[11px] text-gray-600 font-mono mt-1 break-all">
              {sqrtPriceX96?.toString()}
            </p>
          </details>
        </div>
      )}
    </div>
  );
}