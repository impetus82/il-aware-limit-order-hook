/**
 * Uniswap V4 Price Utilities — Multi-Chain (Base & Unichain)
 *
 * Converts sqrtPriceX96 (Q64.96 fixed-point) to a human-readable decimal price.
 *
 * Formula:  price_raw = (sqrtPriceX96 / 2^96)^2
 *
 * CRITICAL: Token sort order differs by chain:
 *   Base:     currency0 = WETH (18 dec), currency1 = USDC (6 dec)  → wethIsCurrency0 = true
 *   Unichain: currency0 = USDC (6 dec),  currency1 = WETH (18 dec) → wethIsCurrency0 = false
 *
 * This function ALWAYS returns "USDC per WETH" for UI consistency,
 * regardless of on-chain token sort order.
 *
 * When wethIsCurrency0 = true  (Base):
 *   price_raw = currency1/currency0 = USDC_raw/WETH_raw
 *   human_price = price_raw * 10^(dec0 - dec1) = price_raw * 10^12
 *
 * When wethIsCurrency0 = false (Unichain):
 *   price_raw = currency1/currency0 = WETH_raw/USDC_raw
 *   We need the INVERSE: USDC/WETH = 1 / (price_raw * 10^(dec0 - dec1))
 *   dec0=6, dec1=18 → adjustment = 10^(6-18) = 10^(-12)
 *   human_price = 1 / (price_raw * 10^(-12)) = 10^12 / price_raw
 */

const Q96 = BigInt(1) << BigInt(96); // 2^96
const PRICE_SCALE = BigInt(10) ** BigInt(18); // 1e18 for intermediate precision

// Uniswap V4 tick boundaries
const MIN_TICK = -887272;
const MAX_TICK = 887272;

/**
 * Convert sqrtPriceX96 (BigInt) → human-readable "USDC per WETH" price.
 *
 * @param sqrtPriceX96  - The sqrtPriceX96 from pool slot0
 * @param wethIsCurrency0 - true on Base (WETH < USDC), false on Unichain (USDC < WETH)
 * @returns price in USDC per WETH (e.g. ~3500.00)
 */
export function sqrtPriceX96ToPrice(
  sqrtPriceX96: bigint,
  wethIsCurrency0: boolean = true,
): number {
  if (sqrtPriceX96 === BigInt(0)) return 0;

  // Decimal difference: |WETH_decimals - USDC_decimals| = 12
  const DECIMAL_ADJUSTMENT = BigInt(10) ** BigInt(12); // 10^12

  if (wethIsCurrency0) {
    // ── Base: currency0=WETH, currency1=USDC ──────────────
    // price_raw = (sqrtPriceX96^2) / 2^192 → "USDC_raw per WETH_raw"
    // human_price = price_raw * 10^(18-6) = price_raw * 10^12
    const numerator = sqrtPriceX96 * sqrtPriceX96 * PRICE_SCALE * DECIMAL_ADJUSTMENT;
    const denominator = Q96 * Q96; // 2^192
    const price1e18 = numerator / denominator;

    const integerPart = price1e18 / PRICE_SCALE;
    const fractionalPart = price1e18 % PRICE_SCALE;
    return Number(integerPart) + Number(fractionalPart) / 1e18;
  } else {
    // ── Unichain: currency0=USDC, currency1=WETH ─────────
    // price_raw = (sqrtPriceX96^2) / 2^192 → "WETH_raw per USDC_raw"
    // To get USDC per WETH: invert and adjust decimals
    // human_price = 10^12 / price_raw
    //
    // Implementation: price_raw_1e18 = (sqrtPriceX96^2 * 1e18) / 2^192
    // Then: result = (10^12 * 1e18) / price_raw_1e18
    const sqrtSq = sqrtPriceX96 * sqrtPriceX96;
    const denominator = Q96 * Q96;

    // price_raw_1e18 = sqrtSq * 1e18 / 2^192
    const priceRaw1e18 = (sqrtSq * PRICE_SCALE) / denominator;

    if (priceRaw1e18 === BigInt(0)) return Infinity;

    // USDC per WETH = DECIMAL_ADJUSTMENT * PRICE_SCALE / priceRaw1e18
    const result1e18 = (DECIMAL_ADJUSTMENT * PRICE_SCALE) / priceRaw1e18;

    const integerPart = result1e18; // already in natural units (no extra 1e18 wrapper)
    return Number(integerPart) + Number((DECIMAL_ADJUSTMENT * PRICE_SCALE) % priceRaw1e18) / Number(priceRaw1e18);
  }
}

/**
 * Check if a tick is at or near the Uniswap boundary (extreme price).
 * Threshold: within 100 ticks of min/max.
 */
export function isExtremeTick(tick: number): boolean {
  return tick >= MAX_TICK - 100 || tick <= MIN_TICK + 100;
}

/**
 * Format price for display with appropriate decimal places.
 * Optimized for USDC-denominated prices (typically $1000-$10000 range for ETH).
 */
export function formatPrice(price: number): string {
  if (price === 0) return "0.00";
  if (!Number.isFinite(price)) return "∞";
  if (price > 1e15) return "∞ (extreme)";
  if (price >= 100) return price.toFixed(2);    // 3500.12 USDC
  if (price >= 1) return price.toFixed(4);       // 1.0034
  if (price >= 0.0001) return price.toFixed(6);  // 0.000285
  if (price >= 1e-12) return price.toFixed(8);
  return "≈ 0";
}

/**
 * Inverse price: if price = USDC/WETH, then inverse = WETH/USDC.
 * For a price of 3500 USDC per WETH, inverse = 0.000285 WETH per USDC.
 */
export function invertPrice(price: number): number {
  if (price === 0 || !Number.isFinite(price) || price > 1e15) return 0;
  return 1 / price;
}

/**
 * Compute trigger price decimals for parseUnits().
 *
 * In the hook contract, triggerPrice is stored as raw_price * 1e18.
 * The user always enters "USDC per WETH" in the form.
 *
 * Formula: parseUnits decimals = 18 + quote_decimals - base_decimals
 *
 * When wethIsCurrency0 = true  (Base):    18 + 6 - 18 = 6
 * When wethIsCurrency0 = false (Unichain): The user enters USDC/WETH,
 *   but on-chain currency0=USDC, currency1=WETH. The contract stores
 *   price as currency1/currency0, so we need WETH/USDC = 1/(user_input).
 *   However, the contract's _isEligible compares rawPrice with triggerPrice
 *   in the SAME direction. So we must store in the on-chain direction.
 *
 *   On Unichain: triggerPrice represents WETH_raw per USDC_raw.
 *   parseUnits decimals = 18 + 18 - 6 = 30
 *   But the user enters USDC/WETH, so we must INVERT before storing.
 *
 * This function returns { decimals, needsInversion }.
 */
export function getTriggerPriceConfig(wethIsCurrency0: boolean) {
  if (wethIsCurrency0) {
    // Base: user enters USDC/WETH, contract stores USDC/WETH
    return {
      decimals: 18 + 6 - 18, // = 6
      needsInversion: false,
    };
  } else {
    // Unichain: user enters USDC/WETH, contract stores WETH/USDC
    // decimals for WETH/USDC = 18 + 18 - 6 = 30
    return {
      decimals: 18 + 18 - 6, // = 30
      needsInversion: true,
    };
  }
}