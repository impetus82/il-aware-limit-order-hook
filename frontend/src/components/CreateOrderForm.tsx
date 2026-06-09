"use client";

/* The React Compiler rules below are over-strict for this component's legitimate
   async approve→create→receipt flow (UI state bridged from
   useWaitForTransactionReceipt, and a handler auto-chained from that effect).
   `next build` is clean; disabling them file-wide avoids whack-a-mole directives. */
/* eslint-disable react-hooks/set-state-in-effect, react-hooks/immutability */

import { useState, useMemo, useEffect } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseUnits, formatUnits, type Address } from "viem";
import {
  getChainContracts,
  getSortedTokens,
  HOOK_ABI,
  ERC20_ABI,
  STATE_VIEW_ABI,
  POOL_FEE,
  TICK_SPACING,
} from "@/config/contracts";
import { getTriggerPriceConfig, sqrtPriceX96ToPrice, formatPrice } from "@/utils/price";
import { extractTxError } from "@/utils/txError";

// ── Types ───────────────────────────────────────────────
type OrderDirection = "sell" | "buy";
type TxStep = "idle" | "approving" | "waitApprove" | "placing" | "waitPlace" | "done";

// uint96 / uint128 maxima
const UINT96_MAX = (1n << 96n) - 1n;
const UINT128_MAX = (1n << 128n) - 1n;

// ── Component ───────────────────────────────────────────
export default function CreateOrderForm({
  onOrderCreated,
}: {
  /** Called after an order is successfully mined */
  onOrderCreated?: () => void;
}) {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);
  const { currency0, currency1 } = getSortedTokens(chainId);

  // Form state
  const [direction, setDirection] = useState<OrderDirection>("sell");
  const [amountIn, setAmountIn] = useState("");
  const [triggerPrice, setTriggerPrice] = useState("");
  const [txStep, setTxStep] = useState<TxStep>("idle");
  const [error, setError] = useState<string | null>(null);

  // ── Token mapping (UI-semantic, not sort-order) ───────
  // "sell" = sell WETH for USDC; "buy" = buy WETH with USDC.
  // On Base (wethIsCurrency0=true): sell WETH = zeroForOne=true
  // On Unichain (wethIsCurrency0=false): buy WETH = sell USDC (cur0) → zeroForOne=true
  const zeroForOne = chain.wethIsCurrency0
    ? direction === "sell"
    : direction === "buy";

  const spendToken = direction === "sell" ? chain.weth : chain.usdc;
  const receiveToken = direction === "sell" ? chain.usdc : chain.weth;

  // ── Hook contract reference ───────────────────────────
  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

  // ── Read: live market price (to anchor the trigger) ───
  const { data: slot0 } = useReadContract({
    address: chain.stateView,
    abi: STATE_VIEW_ABI,
    functionName: "getSlot0",
    args: [chain.poolId],
    query: { refetchInterval: 12_000 },
  });
  const marketPrice = useMemo(() => {
    const sp = slot0?.[0] as bigint | undefined;
    if (!sp) return null;
    const p = sqrtPriceX96ToPrice(sp, chain.wethIsCurrency0);
    return Number.isFinite(p) && p > 0 ? p : null;
  }, [slot0, chain.wethIsCurrency0]);

  // ── Read: user balance ────────────────────────────────
  const { data: userBalance } = useReadContract({
    address: spendToken.address,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // ── Read: current allowance ───────────────────────────
  const { data: currentAllowance, refetch: refetchAllowance } = useReadContract({
    address: spendToken.address,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, chain.hook] : undefined,
    query: { enabled: !!address },
  });

  // ── Write: approve ────────────────────────────────────
  const {
    data: approveTxHash,
    writeContract: writeApprove,
    reset: resetApprove,
  } = useWriteContract();

  const { isSuccess: approveConfirmed, isLoading: approveLoading } =
    useWaitForTransactionReceipt({ hash: approveTxHash });

  // ── Write: createLimitOrder ───────────────────────────
  const {
    data: createTxHash,
    writeContract: writeCreate,
    reset: resetCreate,
  } = useWriteContract();

  const { isSuccess: createConfirmed, isLoading: createLoading } =
    useWaitForTransactionReceipt({ hash: createTxHash });

  // ── Parsed amounts (DECIMAL-AWARE) ────────────────────
  const parsedAmount = useMemo(() => {
    try {
      if (!amountIn || parseFloat(amountIn) <= 0) return null;
      return parseUnits(amountIn, spendToken.decimals);
    } catch {
      return null;
    }
  }, [amountIn, spendToken.decimals]);

  // ── Trigger price parsing ─────────────────────────────
  // User ALWAYS enters "USDC per WETH". Base stores as-is; Unichain inverts.
  const triggerPriceConfig = getTriggerPriceConfig(chain.wethIsCurrency0);

  const parsedTriggerPrice = useMemo(() => {
    try {
      if (!triggerPrice || parseFloat(triggerPrice) <= 0) return null;
      if (triggerPriceConfig.needsInversion) {
        const userPrice = parseFloat(triggerPrice);
        const invertedStr = (1 / userPrice).toFixed(24);
        return parseUnits(invertedStr, triggerPriceConfig.decimals);
      }
      return parseUnits(triggerPrice, triggerPriceConfig.decimals);
    } catch {
      return null;
    }
  }, [triggerPrice, triggerPriceConfig]);

  // ── Validation flags ──────────────────────────────────
  const amountExceedsUint96 = parsedAmount !== null && parsedAmount > UINT96_MAX;
  const triggerOutOfRange =
    parsedTriggerPrice !== null &&
    (parsedTriggerPrice === 0n || parsedTriggerPrice > UINT128_MAX);
  const insufficientBalance =
    parsedAmount !== null &&
    userBalance !== undefined &&
    parsedAmount > (userBalance as bigint);

  const needsApproval =
    parsedAmount !== null &&
    currentAllowance !== undefined &&
    (currentAllowance as bigint) < parsedAmount;

  // ── Estimated output preview ──────────────────────────
  const outputEstimate = useMemo(() => {
    const a = parseFloat(amountIn);
    const t = parseFloat(triggerPrice);
    if (!a || !t || a <= 0 || t <= 0) return null;
    // sell WETH → receive USDC ≈ amount * price; buy WETH → receive ≈ amount / price
    const value = direction === "sell" ? a * t : a / t;
    return { value, symbol: receiveToken.symbol };
  }, [amountIn, triggerPrice, direction, receiveToken.symbol]);

  // ── Effect: after approve confirmed → place order ─────
  useEffect(() => {
    if (approveConfirmed && txStep === "waitApprove") {
      refetchAllowance();
      handlePlaceOrder();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [approveConfirmed]);

  // ── Effect: after create confirmed → done + callback ──
  useEffect(() => {
    if (createConfirmed && txStep === "waitPlace") {
      setTxStep("done");
      onOrderCreated?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [createConfirmed]);

  // Wallet rejections / write errors are handled in each writeContract's
  // onError callback below (avoids setState-in-effect anti-pattern).

  // ── Handlers ──────────────────────────────────────────
  function handleSubmit() {
    setError(null);
    resetApprove();
    resetCreate();

    if (!parsedAmount || !parsedTriggerPrice) {
      setError("Enter valid amount and trigger price");
      return;
    }
    if (amountExceedsUint96) {
      setError("Amount exceeds max uint96 (~79B tokens)");
      return;
    }
    if (triggerOutOfRange) {
      setError("Trigger price is out of range — try a realistic value");
      return;
    }
    if (insufficientBalance) {
      setError(`Insufficient ${spendToken.symbol} balance`);
      return;
    }

    if (needsApproval) {
      setTxStep("approving");
      writeApprove(
        {
          address: spendToken.address,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [chain.hook, parsedAmount],
        },
        {
          onSuccess: () => setTxStep("waitApprove"),
          onError: (err) => {
            setError(extractTxError(err));
            setTxStep("idle");
          },
        }
      );
    } else {
      handlePlaceOrder();
    }
  }

  function handlePlaceOrder() {
    if (!parsedAmount || !parsedTriggerPrice) return;

    setTxStep("placing");

    const poolKeyTuple = {
      currency0: currency0.address as Address,
      currency1: currency1.address as Address,
      fee: POOL_FEE,
      tickSpacing: TICK_SPACING,
      hooks: chain.hook as Address,
    };

    writeCreate(
      {
        ...hookContract,
        functionName: "createLimitOrder",
        args: [poolKeyTuple, zeroForOne, parsedAmount, parsedTriggerPrice],
      },
      {
        onSuccess: () => setTxStep("waitPlace"),
        onError: (err) => {
          setError(extractTxError(err));
          setTxStep("idle");
        },
      }
    );
  }

  function handleReset() {
    setTxStep("idle");
    setAmountIn("");
    setTriggerPrice("");
    setError(null);
    resetApprove();
    resetCreate();
  }

  // ── Validation ────────────────────────────────────────
  const canSubmit =
    isConnected &&
    parsedAmount !== null &&
    parsedTriggerPrice !== null &&
    !amountExceedsUint96 &&
    !triggerOutOfRange &&
    !insufficientBalance &&
    txStep === "idle";

  const explorerName = chain.chainLabel === "BASE" ? "BaseScan" : "Uniscan";
  const inputsDisabled = txStep !== "idle";

  // ── Render ────────────────────────────────────────────
  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
      <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-5">
        Create Limit Order
      </h3>

      {/* Direction Toggle */}
      <div
        role="radiogroup"
        aria-label="Order direction"
        className="flex gap-2 mb-4 sm:mb-5"
      >
        <button
          type="button"
          role="radio"
          aria-checked={direction === "sell"}
          onClick={() => setDirection("sell")}
          disabled={inputsDisabled}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors disabled:opacity-50 ${
            direction === "sell"
              ? "bg-red-500/20 text-red-400 border border-red-500/40"
              : "bg-gray-800 text-gray-400 border border-gray-700 hover:border-gray-600"
          }`}
        >
          Sell WETH → USDC
        </button>
        <button
          type="button"
          role="radio"
          aria-checked={direction === "buy"}
          onClick={() => setDirection("buy")}
          disabled={inputsDisabled}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors disabled:opacity-50 ${
            direction === "buy"
              ? "bg-emerald-500/20 text-emerald-400 border border-emerald-500/40"
              : "bg-gray-800 text-gray-400 border border-gray-700 hover:border-gray-600"
          }`}
        >
          Buy WETH ← USDC
        </button>
      </div>

      {/* Amount Input */}
      <div className="mb-4">
        <label htmlFor="amount-input" className="block text-xs text-gray-500 mb-1.5">
          Amount ({spendToken.symbol})
        </label>
        <div className="relative">
          <input
            id="amount-input"
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amountIn}
            onChange={(e) => {
              const val = e.target.value;
              if (/^[0-9]*\.?[0-9]*$/.test(val)) {
                setAmountIn(val);
                setError(null);
              }
            }}
            disabled={inputsDisabled}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                       placeholder-gray-500 focus:outline-none focus:border-gray-500
                       disabled:opacity-50 font-mono"
          />
          {address && userBalance !== undefined && (
            <button
              type="button"
              aria-label={`Use max ${spendToken.symbol} balance`}
              onClick={() =>
                setAmountIn(formatUnits(userBalance as bigint, spendToken.decimals))
              }
              disabled={inputsDisabled}
              className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-gray-400
                         hover:text-gray-200 transition-colors disabled:opacity-50"
            >
              MAX: {Number(formatUnits(userBalance as bigint, spendToken.decimals)).toFixed(
                spendToken.decimals === 6 ? 2 : 4
              )}
            </button>
          )}
        </div>
        {amountExceedsUint96 && (
          <p className="text-xs text-red-400 mt-1">Exceeds uint96 max (~79B tokens)</p>
        )}
        {!amountExceedsUint96 && insufficientBalance && (
          <p className="text-xs text-red-400 mt-1">
            Insufficient {spendToken.symbol} balance
          </p>
        )}
      </div>

      {/* Trigger Price Input */}
      <div className="mb-4">
        <div className="flex items-center justify-between mb-1.5">
          <label htmlFor="trigger-input" className="block text-xs text-gray-500">
            Trigger Price (USDC per WETH)
          </label>
          {marketPrice !== null && (
            <button
              type="button"
              onClick={() => {
                setTriggerPrice(formatPrice(marketPrice));
                setError(null);
              }}
              disabled={inputsDisabled}
              className="text-[11px] text-gray-500 hover:text-gray-300 transition-colors disabled:opacity-50"
              title="Use the current market price"
            >
              Market ≈ {formatPrice(marketPrice)} · use
            </button>
          )}
        </div>
        <input
          id="trigger-input"
          type="text"
          inputMode="decimal"
          placeholder="3600"
          value={triggerPrice}
          onChange={(e) => {
            const val = e.target.value;
            if (/^[0-9]*\.?[0-9]*$/.test(val)) {
              setTriggerPrice(val);
              setError(null);
            }
          }}
          disabled={inputsDisabled}
          className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                     placeholder-gray-500 focus:outline-none focus:border-gray-500
                     disabled:opacity-50 font-mono"
        />
        {triggerOutOfRange && (
          <p className="text-xs text-red-400 mt-1">
            Trigger price is out of range — try a realistic value
          </p>
        )}
      </div>

      {/* Output estimate + custody note */}
      {outputEstimate && !triggerOutOfRange && (
        <div className="mb-5 rounded-lg bg-gray-800/50 border border-gray-700/60 px-3 py-2">
          <p className="text-xs text-gray-400">
            You&apos;ll receive ≈{" "}
            <span className="text-emerald-400 font-mono">
              {outputEstimate.value.toLocaleString(undefined, { maximumFractionDigits: 6 })}{" "}
              {outputEstimate.symbol}
            </span>{" "}
            when filled.
          </p>
          <p className="text-[11px] text-gray-600 mt-0.5">
            Output is held in the hook until you Claim (then earns optional vault yield + IL rebate).
          </p>
        </div>
      )}

      {/* Error Message */}
      {error && (
        <div className="mb-4 p-3 rounded-lg bg-red-500/10 border border-red-500/30">
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      {/* Submit / Status Button */}
      {txStep === "done" ? (
        <div className="space-y-3">
          <div className="p-3 rounded-lg bg-emerald-500/10 border border-emerald-500/30 text-center">
            <p className="text-sm text-emerald-400 font-medium">
              Order created — minted as ERC-721 NFT
            </p>
            {createTxHash && (
              <a
                href={`${chain.explorerUrl}/tx/${createTxHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-emerald-500/70 hover:text-emerald-400 underline mt-1 inline-block"
              >
                View on {explorerName} ↗
              </a>
            )}
          </div>
          <button
            type="button"
            onClick={handleReset}
            className="w-full py-3 rounded-lg bg-gray-800 text-gray-300
                       hover:bg-gray-700 transition-colors text-sm font-medium"
          >
            Place Another Order
          </button>
        </div>
      ) : (
        <button
          type="button"
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="w-full py-3 rounded-lg font-medium text-sm transition-all
                     disabled:opacity-40 disabled:cursor-not-allowed
                     bg-blue-600 hover:bg-blue-500 text-white"
        >
          <ButtonLabel
            step={txStep}
            needsApproval={needsApproval}
            approveLoading={approveLoading}
            createLoading={createLoading}
          />
        </button>
      )}

      {/* Tx Hash Links (intermediate) */}
      {approveTxHash && txStep === "waitApprove" && (
        <p className="text-xs text-gray-500 text-center mt-2">
          Approve tx:{" "}
          <a
            href={`${chain.explorerUrl}/tx/${approveTxHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400/70 hover:text-blue-400 underline"
          >
            {approveTxHash.slice(0, 10)}…
          </a>
        </p>
      )}
    </div>
  );
}

// ── Helpers ─────────────────────────────────────────────

function ButtonLabel({
  step,
  needsApproval,
  approveLoading,
  createLoading,
}: {
  step: TxStep;
  needsApproval: boolean;
  approveLoading: boolean;
  createLoading: boolean;
}) {
  switch (step) {
    case "approving":
      return <SpinnerText text="Confirm approval in wallet…" />;
    case "waitApprove":
      return <SpinnerText text={approveLoading ? "Waiting for approval…" : "Approve confirmed"} />;
    case "placing":
      return <SpinnerText text="Confirm order in wallet…" />;
    case "waitPlace":
      return <SpinnerText text={createLoading ? "Mining order tx…" : "Almost there…"} />;
    default:
      return <>{needsApproval ? "Approve & Place Order" : "Place Order"}</>;
  }
}

function SpinnerText({ text }: { text: string }) {
  return (
    <span className="inline-flex items-center gap-2">
      <svg aria-hidden="true" className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" className="opacity-25" />
        <path
          d="M4 12a8 8 0 018-8"
          stroke="currentColor"
          strokeWidth="3"
          strokeLinecap="round"
          className="opacity-75"
        />
      </svg>
      {text}
    </span>
  );
}
