import { describe, it, expect } from "vitest";
import { encodeAbiParameters, keccak256 } from "viem";
import {
  DEPLOYMENTS,
  getDeployment,
  buildPoolKey,
  encodeTriggerPrice,
  decodeTriggerPrice,
  createLimitOrderParams,
  claimOrderParams,
  depositToVaultParams,
  cancelOrderParams,
  deriveOrderStatus,
  MAX_TRIGGER_PRICE,
  type LimitOrder,
} from "../src/index.js";

const POOL_KEY_ABI = [
  {
    type: "tuple",
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

/** Uniswap v4: PoolId = keccak256(abi.encode(poolKey)). */
function toPoolId(key: ReturnType<typeof buildPoolKey>): `0x${string}` {
  return keccak256(encodeAbiParameters(POOL_KEY_ABI, [key]));
}

describe("addresses / poolKey", () => {
  // The strongest offline correctness check: hashing the SDK's PoolKey must reproduce the
  // poolId actually emitted on-chain at pool initialization on each chain. Any drift in
  // token addresses, sort order, fee, tickSpacing, or the hook address breaks this.
  it("PoolKey hashes to the REAL on-chain poolId (Base)", () => {
    expect(toPoolId(buildPoolKey(8453))).toBe(DEPLOYMENTS[8453].poolId);
  });

  it("PoolKey hashes to the REAL on-chain poolId (Unichain)", () => {
    expect(toPoolId(buildPoolKey(130))).toBe(DEPLOYMENTS[130].poolId);
  });

  it("currency0 < currency1 (v4 sort invariant) on both chains", () => {
    for (const id of [8453, 130] as const) {
      const k = buildPoolKey(id);
      expect(BigInt(k.currency0) < BigInt(k.currency1)).toBe(true);
    }
  });

  it("wethIsCurrency0 matches the actual sort", () => {
    expect(buildPoolKey(8453).currency0).toBe(DEPLOYMENTS[8453].weth.address); // Base: WETH first
    expect(buildPoolKey(130).currency0).toBe(DEPLOYMENTS[130].usdc.address); // Unichain: USDC first
  });

  it("rejects unsupported chains", () => {
    expect(() => getDeployment(1)).toThrow(/not deployed/);
  });
});

describe("encodeTriggerPrice", () => {
  it("Base: stores USDC/WETH as-is with 6 decimals (exact)", () => {
    expect(encodeTriggerPrice(8453, "1866.47")).toBe(1_866_470_000n);
    expect(encodeTriggerPrice(8453, 2000)).toBe(2_000_000_000n);
  });

  it("Unichain: stores the INVERTED price with 30 decimals (≈ 1e30 / P)", () => {
    const p = 1866.47;
    const enc = encodeTriggerPrice(130, p);
    const ideal = 1e30 / p;
    expect(Math.abs(Number(enc) - ideal) / ideal).toBeLessThan(1e-12);
  });

  it("round-trips through decode on both chains", () => {
    for (const id of [8453, 130] as const) {
      for (const p of [0.5, 1, 1866.47, 250_000]) {
        const back = decodeTriggerPrice(id, encodeTriggerPrice(id, p));
        expect(Math.abs(back - p) / p).toBeLessThan(1e-9);
      }
    }
  });

  it("rejects zero / negative / non-finite prices", () => {
    for (const bad of [0, -5, NaN, Infinity]) {
      expect(() => encodeTriggerPrice(8453, bad)).toThrow();
    }
  });

  it("rejects prices whose encoding would exceed MAX_TRIGGER_PRICE (hook would revert)", () => {
    // Unichain inverts: a tiny USDC/WETH price → huge stored value > 1e36.
    expect(() => encodeTriggerPrice(130, 0.00000009)).toThrow(/MAX_TRIGGER_PRICE/);
    // Base stores directly: price above 1e30 → encoded > 1e36.
    expect(() => encodeTriggerPrice(8453, 1e31)).toThrow(/MAX_TRIGGER_PRICE/);
    expect(MAX_TRIGGER_PRICE).toBe(10n ** 36n);
  });

  it("rejects prices too small to represent (would encode to zero)", () => {
    expect(() => encodeTriggerPrice(8453, "0.0000001")).toThrow(/zero/);
  });
});

describe("createLimitOrderParams", () => {
  it("derives zeroForOne from the sell token per chain's sort order", () => {
    // zeroForOne === selling currency0. WETH is currency0 on Base, currency1 on Unichain.
    expect(createLimitOrderParams({ chainId: 8453, sell: "WETH", amountIn: "0.05", triggerPriceUsdcPerWeth: 1900 }).args[1]).toBe(true);
    expect(createLimitOrderParams({ chainId: 8453, sell: "USDC", amountIn: "150", triggerPriceUsdcPerWeth: 1800 }).args[1]).toBe(false);
    expect(createLimitOrderParams({ chainId: 130, sell: "WETH", amountIn: "0.05", triggerPriceUsdcPerWeth: 1900 }).args[1]).toBe(false);
    expect(createLimitOrderParams({ chainId: 130, sell: "USDC", amountIn: "150", triggerPriceUsdcPerWeth: 1800 }).args[1]).toBe(true);
  });

  it("parses amountIn in the SELL token's own decimals", () => {
    expect(createLimitOrderParams({ chainId: 8453, sell: "WETH", amountIn: "0.05", triggerPriceUsdcPerWeth: 1900 }).args[2]).toBe(50_000_000_000_000_000n); // 18 dec
    expect(createLimitOrderParams({ chainId: 8453, sell: "USDC", amountIn: "150", triggerPriceUsdcPerWeth: 1800 }).args[2]).toBe(150_000_000n); // 6 dec
  });

  it("enforces the hook's uint96 amount bound", () => {
    // 8e10 WETH = 8e28 wei > uint96 max (~7.9e28) → the hook would revert; the SDK fails fast.
    expect(() =>
      createLimitOrderParams({ chainId: 8453, sell: "WETH", amountIn: "80000000000", triggerPriceUsdcPerWeth: 1900 }),
    ).toThrow(/uint96/);
    expect(() =>
      createLimitOrderParams({ chainId: 8453, sell: "WETH", amountIn: "0", triggerPriceUsdcPerWeth: 1900 }),
    ).toThrow(/positive/);
  });

  it("targets the chain's hook with the canonical PoolKey", () => {
    const p = createLimitOrderParams({ chainId: 130, sell: "USDC", amountIn: "10", triggerPriceUsdcPerWeth: 1866 });
    expect(p.address).toBe(DEPLOYMENTS[130].hook);
    expect(p.args[0]).toEqual(buildPoolKey(130));
    expect(p.functionName).toBe("createLimitOrder");
  });
});

describe("claim / deposit / cancel params", () => {
  it("claimOrderParams auto-supplies the FULL PoolKey tuple (the #1 integration footgun)", () => {
    const p = claimOrderParams(8453, 7n);
    expect(p.functionName).toBe("claimOrder");
    expect(p.args[0]).toBe(7n);
    expect(p.args[1]).toEqual(buildPoolKey(8453));
    expect(p.address).toBe(DEPLOYMENTS[8453].hook);
  });

  it("depositToVault / cancelOrder take just the orderId", () => {
    expect(depositToVaultParams(130, 3n).args).toEqual([3n]);
    expect(cancelOrderParams(130, 3n).args).toEqual([3n]);
  });
});

describe("deriveOrderStatus", () => {
  const base: LimitOrder = {
    amount0: 0n, amount1: 0n,
    token0: "0x0000000000000000000000000000000000000001",
    token1: "0x0000000000000000000000000000000000000002",
    triggerPrice: 1n, createdAt: 1n, isFilled: false, zeroForOne: true,
    vaultShares: 0n, sqrtPriceAtFill: 0n,
    poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
  };
  const owner = "0x8114cdc7dDEa2Be36435351dB2115887daEF5e12" as const;

  it("mirrors the reference UI's status derivation", () => {
    expect(deriveOrderStatus({ ...base, isFilled: false }, owner)).toBe("active");
    expect(deriveOrderStatus({ ...base, isFilled: true }, owner)).toBe("filled");
    expect(deriveOrderStatus({ ...base, isFilled: true }, null)).toBe("claimed"); // burned + filled
    expect(deriveOrderStatus({ ...base, isFilled: false }, null)).toBe("cancelled"); // burned + unfilled
  });
});
