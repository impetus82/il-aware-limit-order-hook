import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { Providers } from "@/components/providers";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "IL-Aware Limit Order Hook | Uniswap V4",
  description:
    "Yield-bearing, IL-aware limit orders on Uniswap V4. Every order is an ERC-721 NFT; filled output earns simulated vault yield and pays an impermanent-loss rebate on claim.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className={inter.className}>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
