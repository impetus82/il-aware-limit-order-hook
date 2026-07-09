import { describe, it, expect } from "vitest";
import {
  sqrtPriceX96ToPrice,
  isExtremeTick,
  formatPrice,
  invertPrice,
  getTriggerPriceConfig,
} from "./price";

const Q96 = 1n << 96n; // 2^96 → sqrtPrice == 1

// Independent float reference for sqrtPriceX96ToPrice, derived straight from the
// Uniswap formula (a DIFFERENT implementation than the BigInt one under test):
//   priceRaw = (sqrtPriceX96 / 2^96)^2 = currency1_raw / currency0_raw
//   Base (WETH=cur0 18d, USDC=cur1 6d):  USDC/WETH = priceRaw * 10^(18-6)
//   Unichain (USDC=cur0 6d, WETH=cur1 18d): USDC/WETH = 10^(18-6) / priceRaw
function referencePrice(sqrtPriceX96: bigint, wethIsCurrency0: boolean): number {
  const sp = Number(sqrtPriceX96) / 2 ** 96;
  const priceRaw = sp * sp;
  return wethIsCurrency0 ? priceRaw * 1e12 : 1e12 / priceRaw;
}

// Assert relative error (toBeCloseTo is absolute-digit based → wrong for large prices).
function expectClose(actual: number, expected: number, rel = 1e-4) {
  expect(Math.abs(actual - expected) / expected).toBeLessThan(rel);
}

describe("sqrtPriceX96ToPrice", () => {
  it("returns 0 for a zero sqrtPrice", () => {
    expect(sqrtPriceX96ToPrice(0n, true)).toBe(0);
    expect(sqrtPriceX96ToPrice(0n, false)).toBe(0);
  });

  it("gives the decimal-adjusted price at sqrtPrice == 1 (priceRaw == 1)", () => {
    // priceRaw = 1 → both orientations collapse to the 10^12 decimal adjustment.
    expect(sqrtPriceX96ToPrice(Q96, true)).toBe(1e12);
    expect(sqrtPriceX96ToPrice(Q96, false)).toBe(1e12);
  });

  it("scales correctly at sqrtPrice == 2 (priceRaw == 4)", () => {
    expectClose(sqrtPriceX96ToPrice(2n * Q96, true), 4e12); // Base: 4 * 1e12
    expectClose(sqrtPriceX96ToPrice(2n * Q96, false), 2.5e11); // Unichain: 1e12 / 4
  });

  it("matches the independent float reference across both orientations", () => {
    const samples: bigint[] = [
      Q96 / 1000n,
      Q96,
      2n * Q96,
      1000n * Q96,
      1833872557329114370356651893539842n, // live Unichain pool value (see below)
    ];
    for (const sp of samples) {
      expectClose(sqrtPriceX96ToPrice(sp, true), referencePrice(sp, true));
      expectClose(sqrtPriceX96ToPrice(sp, false), referencePrice(sp, false));
    }
  });

  it("converts the live Unichain pool sqrtPrice to ~1866 USDC/WETH", () => {
    // Ground truth captured from mainnet: getSlot0 → sqrtPriceX96, tick 201002,
    // UI showed 1866.47 USDC/WETH. Unichain has USDC as currency0 (wethIsCurrency0=false).
    const live = 1833872557329114370356651893539842n;
    const price = sqrtPriceX96ToPrice(live, false);
    expect(price).toBeGreaterThan(1860);
    expect(price).toBeLessThan(1872);
  });
});

describe("getTriggerPriceConfig", () => {
  it("Base: user & contract both store USDC/WETH → decimals 6, no inversion", () => {
    expect(getTriggerPriceConfig(true)).toEqual({ decimals: 6, needsInversion: false });
  });

  it("Unichain: contract stores WETH/USDC → decimals 30, needs inversion", () => {
    expect(getTriggerPriceConfig(false)).toEqual({ decimals: 30, needsInversion: true });
  });
});

describe("invertPrice", () => {
  it("inverts a normal price", () => {
    expectClose(invertPrice(2000), 0.0005);
  });

  it("round-trips", () => {
    expectClose(invertPrice(invertPrice(1866.47)), 1866.47);
  });

  it("guards zero / non-finite / extreme inputs", () => {
    expect(invertPrice(0)).toBe(0);
    expect(invertPrice(Infinity)).toBe(0);
    expect(invertPrice(Number.NaN)).toBe(0);
    expect(invertPrice(2e15)).toBe(0); // > 1e15 guard
  });
});

describe("formatPrice", () => {
  it("formats by magnitude band", () => {
    expect(formatPrice(0)).toBe("0.00");
    expect(formatPrice(3500.12)).toBe("3500.12"); // >= 100 → 2dp
    expect(formatPrice(1.0034)).toBe("1.0034"); // >= 1 → 4dp
    expect(formatPrice(0.000285)).toBe("0.000285"); // >= 1e-4 → 6dp
  });

  it("handles non-finite and extreme values", () => {
    expect(formatPrice(Infinity)).toBe("∞");
    expect(formatPrice(Number.NaN)).toBe("∞");
    expect(formatPrice(2e15)).toBe("∞ (extreme)"); // > 1e15
  });
});

describe("isExtremeTick", () => {
  it("flags ticks within 100 of the Uniswap boundaries", () => {
    expect(isExtremeTick(887272)).toBe(true); // MAX_TICK
    expect(isExtremeTick(887172)).toBe(true); // MAX_TICK - 100
    expect(isExtremeTick(-887272)).toBe(true); // MIN_TICK
    expect(isExtremeTick(-887172)).toBe(true); // MIN_TICK + 100
  });

  it("does not flag normal ticks", () => {
    expect(isExtremeTick(0)).toBe(false);
    expect(isExtremeTick(201002)).toBe(false); // live pool tick
    expect(isExtremeTick(887171)).toBe(false); // just inside MAX_TICK - 100
  });
});
