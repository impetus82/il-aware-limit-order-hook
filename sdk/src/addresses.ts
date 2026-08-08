/**
 * Per-chain deployment addresses for ILAwareLimitOrderHook.
 *
 * Token sort order differs per chain and drives everything else (PoolKey layout,
 * zeroForOne direction, trigger-price encoding):
 *   Base (8453):     WETH (0x4200…) < USDC (0x8335…) → currency0 = WETH
 *   Unichain (130):  USDC (0x078d…) < WETH (0x4200…) → currency0 = USDC
 */

export interface TokenInfo {
  readonly address: `0x${string}`;
  readonly symbol: "WETH" | "USDC";
  readonly decimals: number;
}

export interface ChainDeployment {
  readonly chainId: 8453 | 130;
  readonly chainLabel: "BASE" | "UNICHAIN";
  readonly hook: `0x${string}`;
  readonly poolManager: `0x${string}`;
  readonly stateView: `0x${string}`;
  readonly weth: TokenInfo;
  readonly usdc: TokenInfo;
  /** keccak256(abi.encode(poolKey)) of the canonical WETH/USDC pool this hook serves. */
  readonly poolId: `0x${string}`;
  readonly poolFee: number;
  readonly tickSpacing: number;
  /** true → currency0 = WETH (Base); false → currency0 = USDC (Unichain). */
  readonly wethIsCurrency0: boolean;
  /** The ERC-4626 yieldVault the hook is wired to (immutable in the hook). */
  readonly vault: { readonly kind: "aave" | "simulated"; readonly label: string };
  readonly explorerUrl: string;
}

const WETH_BASE: TokenInfo = {
  address: "0x4200000000000000000000000000000000000006",
  symbol: "WETH",
  decimals: 18,
};

export const DEPLOYMENTS: Record<8453 | 130, ChainDeployment> = {
  // ── Base mainnet — production hook wired to REAL Aave (waBasUSDC) ──
  8453: {
    chainId: 8453,
    chainLabel: "BASE",
    hook: "0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce",
    poolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    stateView: "0xa3c0c9b65bad0b08107aa264b0f3db444b867a71",
    weth: WETH_BASE,
    usdc: {
      address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      symbol: "USDC",
      decimals: 6,
    },
    poolId: "0xc92fdde3c2264c8abe30cea3ee4d3ffeeef6ca009117e843158f8f8a5fe6f03e",
    poolFee: 3000,
    tickSpacing: 60,
    wethIsCurrency0: true,
    vault: { kind: "aave", label: "real Aave USDC yield (waBasUSDC)" },
    explorerUrl: "https://basescan.org",
  },

  // ── Unichain mainnet — demo vault (no Aave on Unichain) ──
  130: {
    chainId: 130,
    chainLabel: "UNICHAIN",
    hook: "0x3983130fcd18606afe659acdddb0018d21c254ce",
    poolManager: "0x1F98400000000000000000000000000000000004",
    stateView: "0x86e8631a016f9068c3f085faf484ee3f5fdee8f2",
    weth: WETH_BASE, // same OP-stack predeploy address on Unichain
    usdc: {
      address: "0x078D782b760474a361dDA0AF3839290b0EF57AD6",
      symbol: "USDC",
      decimals: 6,
    },
    poolId: "0x093ab4b09860ac96a823165918b56e35837631d16440daa15385b3f0d7b23279",
    poolFee: 3000,
    tickSpacing: 60,
    wethIsCurrency0: false,
    vault: { kind: "simulated", label: "simulated 3% APY (demo vault)" },
    explorerUrl: "https://uniscan.xyz",
  },
} as const;

export type SupportedChainId = keyof typeof DEPLOYMENTS;

export function getDeployment(chainId: number): ChainDeployment {
  const d = DEPLOYMENTS[chainId as SupportedChainId];
  if (!d) {
    throw new Error(
      `ILAwareLimitOrderHook is not deployed on chainId ${chainId}. Supported: 8453 (Base), 130 (Unichain).`,
    );
  }
  return d;
}

/** The Uniswap v4 PoolKey struct for the canonical WETH/USDC pool on a chain. */
export function buildPoolKey(chainId: number) {
  const d = getDeployment(chainId);
  const [currency0, currency1] = d.wethIsCurrency0
    ? [d.weth.address, d.usdc.address]
    : [d.usdc.address, d.weth.address];
  return {
    currency0,
    currency1,
    fee: d.poolFee,
    tickSpacing: d.tickSpacing,
    hooks: d.hook,
  } as const;
}
