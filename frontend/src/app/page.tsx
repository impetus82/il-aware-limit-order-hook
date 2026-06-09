"use client";

import { useState, useCallback } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useReadContract, useAccount, useChainId, useSwitchChain } from "wagmi";
import { useQueryClient, useIsFetching } from "@tanstack/react-query";
import {
  getChainContracts,
  HOOK_ABI,
  isSupportedChain,
  VAULT_APY_LABEL,
} from "@/config/contracts";
import CreateOrderForm from "@/components/CreateOrderForm";
import OrderList from "@/components/OrderList";
import PoolInfo from "@/components/PoolInfo";

const UNICHAIN_ID = 130;

function Skeleton() {
  return (
    <span className="inline-block w-12 h-5 bg-gray-800 rounded animate-pulse" />
  );
}

export default function Home() {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);
  const supported = isSupportedChain(chainId);
  const wrongNetwork = isConnected && !supported;

  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

  // Global refetch counter — increment to nudge child reads (order cards) to refetch
  const [refetchKey, setRefetchKey] = useState(0);

  // Live "updating…" affordance driven by react-query's in-flight count
  const queryClient = useQueryClient();
  const fetchingCount = useIsFetching();

  const { switchChain, isPending: switching } = useSwitchChain();

  const { data: feeBps, isLoading: feeLoading } = useReadContract({
    ...hookContract,
    functionName: "feeBps",
    query: { refetchInterval: 12_000, enabled: supported },
  });

  const { data: nextOrderId, isLoading: orderLoading } = useReadContract({
    ...hookContract,
    functionName: "nextOrderId",
    query: { refetchInterval: 12_000, enabled: supported },
  });

  // One button to force-refresh every on-chain read (pool, orders, ownerOf, fee, count).
  const handleRefresh = useCallback(() => {
    queryClient.invalidateQueries();
    setRefetchKey((k) => k + 1);
  }, [queryClient]);

  const handleDataChanged = useCallback(() => {
    setRefetchKey((k) => k + 1);
    queryClient.invalidateQueries();
  }, [queryClient]);

  const shortHook = chain.hook.slice(0, 6) + "..." + chain.hook.slice(-4);

  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <header className="flex flex-col sm:flex-row items-center justify-between gap-3 px-4 sm:px-6 py-3 sm:py-4 border-b border-gray-800">
        <h1 className="text-lg sm:text-xl font-bold tracking-tight">
          <span className="bg-gradient-to-r from-emerald-400 to-blue-400 bg-clip-text text-transparent">
            IL-Aware
          </span>{" "}
          Limit Orders
          <span className="ml-2 text-xs font-normal text-gray-500">
            Uniswap V4 · Unichain
          </span>
        </h1>
        <div className="flex items-center gap-2">
          {isConnected && (
            <button
              onClick={handleRefresh}
              aria-label="Refresh on-chain data"
              title="Refresh on-chain data"
              className="inline-flex items-center gap-1.5 rounded-lg border border-gray-700 bg-gray-900 px-2.5 py-1.5 text-xs text-gray-300 hover:border-gray-500 hover:text-white transition-colors"
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
          <ConnectButton />
        </div>
      </header>

      <div className="max-w-2xl mx-auto mt-6 sm:mt-12 px-4 sm:px-6 space-y-4 sm:space-y-6">
        <div className="text-center mb-2">
          <h2 className="text-2xl sm:text-3xl font-bold mb-2 sm:mb-3">
            Yield-bearing, IL-aware limit orders
          </h2>
          <p className="text-gray-400">
            Place limit orders directly on Uniswap V4. No off-chain relayers,
            no trust assumptions.
          </p>
        </div>

        {/* How it works — the three differentiators, always visible for judges */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 sm:gap-3">
          <HowItWorks
            tag="ERC-721"
            title="Orders are NFTs"
            body="Every order mints an ERC-721 — transferable & composable."
          />
          <HowItWorks
            tag="ERC-4626"
            title="Idle output earns"
            body="Filled output can be deposited to a vault (simulated 3% APY)."
          />
          <HowItWorks
            tag="Oracle-free"
            title="IL rebate on claim"
            body="On claim you get output + rebate = min(yield, impermanent loss)."
          />
        </div>

        {/* Wrong-network banner — the biggest live-demo hazard */}
        {wrongNetwork && (
          <div className="rounded-xl border border-yellow-700/60 bg-yellow-950/30 p-4 flex flex-col sm:flex-row items-center justify-between gap-3">
            <div>
              <p className="text-yellow-300 text-sm font-medium">
                Wrong network
              </p>
              <p className="text-yellow-500/80 text-xs mt-0.5">
                This app runs on Unichain. Switch networks to place and manage
                orders.
              </p>
            </div>
            <button
              onClick={() => switchChain({ chainId: UNICHAIN_ID })}
              disabled={switching}
              className="shrink-0 rounded-lg bg-yellow-500/20 border border-yellow-500/40 px-4 py-2 text-sm text-yellow-300 hover:bg-yellow-500/30 transition-colors disabled:opacity-50"
            >
              {switching ? "Switching…" : "Switch to Unichain"}
            </button>
          </div>
        )}

        {/* Live Pool Price — read-only, no wallet needed */}
        {supported && <PoolInfo />}

        {/* Contract Status Card */}
        {supported && (
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
                <span className="text-gray-400">Hook Fee</span>
                <span className="text-white font-mono">
                  {feeLoading ? (
                    <Skeleton />
                  ) : (
                    `${feeBps?.toString() ?? "—"} bps (${Number(feeBps ?? 0) / 100}%)`
                  )}
                </span>
              </div>

              <div className="flex justify-between items-center">
                <span className="text-gray-400">Yield Vault</span>
                <span className="text-gray-300 font-mono text-sm">
                  {VAULT_APY_LABEL}
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
        )}

        {/* Create Order Form (only when connected to a supported chain) */}
        {isConnected && !wrongNetwork ? (
          <CreateOrderForm onOrderCreated={handleDataChanged} />
        ) : (
          !wrongNetwork && (
            <div className="rounded-xl border border-dashed border-gray-700 p-8 text-center">
              <p className="text-gray-400 text-sm">
                Connect your wallet to place limit orders
              </p>
              <p className="text-gray-600 text-xs mt-1">
                Each order is minted to you as an ERC-721 NFT.
              </p>
            </div>
          )
        )}

        {/* Order List */}
        {isConnected && !wrongNetwork && (
          <OrderList refetchKey={refetchKey} onRefresh={handleRefresh} />
        )}

        {isConnected && !wrongNetwork && (
          <p className="text-center text-xs text-gray-500">
            Connected to {chain.chainLabel}
          </p>
        )}
      </div>
    </main>
  );
}

// ── How-it-works tile ───────────────────────────────────
function HowItWorks({
  tag,
  title,
  body,
}: {
  tag: string;
  title: string;
  body: string;
}) {
  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900/60 p-3">
      <span className="inline-block text-[10px] font-mono uppercase tracking-wider text-emerald-400/80 bg-emerald-500/10 border border-emerald-500/20 px-1.5 py-0.5 rounded">
        {tag}
      </span>
      <p className="text-sm font-medium text-white mt-2">{title}</p>
      <p className="text-xs text-gray-400 mt-1 leading-relaxed">{body}</p>
    </div>
  );
}
