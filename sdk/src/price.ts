/**
 * Trigger-price encoding for ILAwareLimitOrderHook.
 *
 * The hook stores `triggerPrice` as the RAW pool price (currency1 per currency0) scaled to 1e18,
 * and compares it against the live pool price in the SAME orientation. Humans quote WETH/USDC
 * pools as "USDC per WETH", so the encoding depends on the chain's token sort order:
 *
 *   Base (currency0 = WETH):     stored = P_usdc_per_weth      scaled by 10^(18 + 6 − 18) = 10^6
 *   Unichain (currency0 = USDC): stored = 1 / P_usdc_per_weth  scaled by 10^(18 + 18 − 6) = 10^30
 *
 * This module reproduces the reference frontend's encoding EXACTLY (including the
 * `(1/P).toFixed(24)` inversion step), so SDK-built orders match UI-built orders bit-for-bit.
 */

import { parseUnits } from "viem";
import { getDeployment } from "./addresses.js";

/** Hook-enforced bound (L1): createLimitOrder reverts above this. */
export const MAX_TRIGGER_PRICE = 10n ** 36n;

export const UINT96_MAX = (1n << 96n) - 1n;
export const UINT128_MAX = (1n << 128n) - 1n;

export function getTriggerPriceConfig(wethIsCurrency0: boolean): {
  decimals: number;
  needsInversion: boolean;
} {
  return wethIsCurrency0
    ? { decimals: 6, needsInversion: false } // Base: store USDC/WETH as-is
    : { decimals: 30, needsInversion: true }; // Unichain: store WETH/USDC (inverted)
}

/**
 * Render a positive finite number as a plain decimal string (never exponential notation,
 * which `parseUnits` rejects). Floats >= 2^53 are always integer-valued → exact via BigInt;
 * everything else is < 1e21 so only the tiny-value (< 1e-6) exponent case needs toFixed.
 */
function toDecimalString(p: number): string {
  if (Number.isInteger(p)) return BigInt(p).toString();
  const s = p.toString();
  return s.includes("e") || s.includes("E") ? p.toFixed(20) : s;
}

/**
 * Encode a human "USDC per WETH" price into the hook's on-chain `triggerPrice` (uint128).
 *
 * @param chainId 8453 (Base) or 130 (Unichain)
 * @param usdcPerWeth e.g. 1866.47 or "1866.47"
 */
export function encodeTriggerPrice(chainId: number, usdcPerWeth: number | string): bigint {
  const p = typeof usdcPerWeth === "string" ? parseFloat(usdcPerWeth) : usdcPerWeth;
  if (!Number.isFinite(p) || p <= 0) {
    throw new Error(`triggerPrice must be a positive finite number, got ${usdcPerWeth}`);
  }
  const { decimals, needsInversion } = getTriggerPriceConfig(getDeployment(chainId).wethIsCurrency0);

  // Mirror the reference frontend exactly: invert in float with 24 fixed decimals, then parseUnits.
  // Direct-path inputs are normalized to plain decimal strings (exact-decimal strings pass through
  // untouched so SDK-encoded orders match UI-encoded orders bit-for-bit).
  const direct =
    typeof usdcPerWeth === "string" && !/e/i.test(usdcPerWeth) ? usdcPerWeth : toDecimalString(p);
  const encoded = needsInversion ? parseUnits((1 / p).toFixed(24), decimals) : parseUnits(direct, decimals);

  if (encoded <= 0n) throw new Error(`encoded triggerPrice is zero — price ${p} too small to represent`);
  if (encoded > MAX_TRIGGER_PRICE) {
    throw new Error(
      `encoded triggerPrice ${encoded} exceeds MAX_TRIGGER_PRICE (1e36) — the hook would revert InvalidTriggerPrice`,
    );
  }
  return encoded;
}

/** Decode an on-chain `triggerPrice` back into a human "USDC per WETH" number (display precision). */
export function decodeTriggerPrice(chainId: number, stored: bigint): number {
  const { decimals, needsInversion } = getTriggerPriceConfig(getDeployment(chainId).wethIsCurrency0);
  const raw = Number(stored) / 10 ** decimals;
  if (raw === 0) return 0;
  return needsInversion ? 1 / raw : raw;
}
