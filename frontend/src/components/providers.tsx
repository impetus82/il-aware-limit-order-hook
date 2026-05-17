"use client";

import { ReactNode } from "react";
import { WagmiProvider, http } from "wagmi";
import { base } from "wagmi/chains";
import { defineChain } from "viem";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, getDefaultConfig } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";

// ── Unichain definition (not yet in wagmi/chains) ──────
export const unichain = defineChain({
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://mainnet.unichain.org"] },
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

const WALLETCONNECT_PROJECT_ID = "9510c31cbc488ccbbe6d7744ad750af1";

const config = getDefaultConfig({
  appName: "Limit Order Hook",
  projectId: WALLETCONNECT_PROJECT_ID,
  chains: [base, unichain],
  transports: {
    [base.id]: http("https://mainnet.base.org"),
    [unichain.id]: http("https://mainnet.unichain.org"),
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