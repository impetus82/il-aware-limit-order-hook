"use client";

import { ReactNode } from "react";
import { WagmiProvider, http } from "wagmi";
import { base } from "wagmi/chains";
import { defineChain } from "viem";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, getDefaultConfig } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";

// ── RPC endpoints & WalletConnect id ────────────────────
// Overridable via env (NEXT_PUBLIC_* — inlined at build time) so a production
// deploy can point at a dedicated/paid RPC instead of the rate-limited public
// endpoints. Fallbacks keep the current public-RPC behavior when unset.
const UNICHAIN_RPC_URL =
  process.env.NEXT_PUBLIC_UNICHAIN_RPC_URL ?? "https://mainnet.unichain.org";
const BASE_RPC_URL =
  process.env.NEXT_PUBLIC_BASE_RPC_URL ?? "https://mainnet.base.org";
const WALLETCONNECT_PROJECT_ID =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "9510c31cbc488ccbbe6d7744ad750af1";

// ── Unichain definition (not yet in wagmi/chains) ──────
export const unichain = defineChain({
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [UNICHAIN_RPC_URL] },
  },
  blockExplorers: {
    default: { name: "Uniscan", url: "https://uniscan.xyz" },
  },
  contracts: {
    multicall3: {
      address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    },
  },
});

const config = getDefaultConfig({
  appName: "IL-Aware Limit Order Hook",
  projectId: WALLETCONNECT_PROJECT_ID,
  // Unichain first → it's the primary Hookathon target and RainbowKit's default.
  chains: [unichain, base],
  transports: {
    [unichain.id]: http(UNICHAIN_RPC_URL),
    [base.id]: http(BASE_RPC_URL),
  },
  ssr: true,
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}