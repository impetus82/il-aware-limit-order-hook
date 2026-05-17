"use client";

import { useState, useCallback } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useReadContract, useAccount, useChainId } from "wagmi";
import { getChainContracts, HOOK_ABI } from "@/config/contracts";
import CreateOrderForm from "@/components/CreateOrderForm";
import OrderList from "@/components/OrderList";
import PoolInfo from "@/components/PoolInfo";

function Skeleton() {
  return (
    <span className="inline-block w-12 h-5 bg-gray-800 rounded animate-pulse" />
  );
}

export default function Home() {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);

  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

  // Global refetch counter — increment to trigger all data refreshes
  const [refetchKey, setRefetchKey] = useState(0);

  const { data: feeBps, isLoading: feeLoading, refetch: refetchFee } = useReadContract({
    ...hookContract,
    functionName: "feeBps",
    query: { refetchInterval: 12_000 },
  });

  const { data: nextOrderId, isLoading: orderLoading, refetch: refetchOrderCount } = useReadContract({
    ...hookContract,
    functionName: "nextOrderId",
    query: { refetchInterval: 12_000 },
  });

  const handleDataChanged = useCallback(() => {
    setRefetchKey((k) => k + 1);
    refetchFee();
    refetchOrderCount();
  }, [refetchFee, refetchOrderCount]);

  const shortHook = chain.hook.slice(0, 6) + "..." + chain.hook.slice(-4);

  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <header className="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 sm:px-6 py-3 sm:py-4 border-b border-gray-800">
        <h1 className="text-lg sm:text-xl font-bold tracking-tight">
          Limit Order Hook
          <span className="ml-2 text-xs font-normal text-gray-500">Uniswap V4</span>
        </h1>
        <ConnectButton />
      </header>

      <div className="max-w-2xl mx-auto mt-6 sm:mt-12 px-4 sm:px-6 space-y-4 sm:space-y-6">
        <div className="text-center mb-8">
          <h2 className="text-2xl sm:text-3xl font-bold mb-2 sm:mb-3">On-chain Limit Orders</h2>
          <p className="text-gray-400">
            Place limit orders directly on Uniswap V4 pools. No off-chain
            relayers, no trust assumptions.
          </p>
        </div>

        {/* Live Pool Price — always visible (read-only, no wallet needed) */}
        <PoolInfo />

        {/* Contract Status Card */}
        <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
          <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">
            Contract Status — {chain.chainLabel}
          </h3>

          <div className="space-y-4">
            <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1">
              <span className="text-gray-400 text-sm">Hook Address</span>
              <a
                href={`${chain.explorerUrl}/address/${chain.hook}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs sm:text-sm text-emerald-400 bg-gray-800 px-2 py-1 rounded break-all hover:text-emerald-300 transition-colors"
              >
                {shortHook}
              </a>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Fee</span>
              <span className="text-white font-mono">
                {feeLoading ? (
                  <Skeleton />
                ) : (
                  `${feeBps?.toString() ?? "—"} bps (${Number(feeBps ?? 0) / 100}%)`
                )}
              </span>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Total Orders</span>
              <span className="text-white font-mono">
                {orderLoading ? <Skeleton /> : nextOrderId?.toString() ?? "—"}
              </span>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Wallet</span>
              <span
                className={`font-mono ${isConnected ? "text-emerald-400" : "text-yellow-500"}`}
              >
                {isConnected ? "Connected" : "Not connected"}
              </span>
            </div>
          </div>
        </div>

        {/* Create Order Form (only when connected) */}
        {isConnected ? (
          <CreateOrderForm onOrderCreated={handleDataChanged} />
        ) : (
          <div className="rounded-xl border border-dashed border-gray-700 p-8 text-center">
            <p className="text-gray-500 text-sm">
              Connect your wallet to place limit orders
            </p>
          </div>
        )}

        {/* Order List */}
        {isConnected && <OrderList refetchKey={refetchKey} />}

        {isConnected && (
          <p className="text-center text-xs text-gray-600">
            Connected to {chain.chainLabel}
          </p>
        )}
      </div>
    </main>
  );
}