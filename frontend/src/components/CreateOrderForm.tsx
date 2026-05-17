"use client";

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
  POOL_FEE,
  TICK_SPACING,
} from "@/config/contracts";
import { getTriggerPriceConfig } from "@/utils/price";

// ── Types ───────────────────────────────────────────────
type OrderDirection = "sell" | "buy";
type TxStep = "idle" | "approving" | "waitApprove" | "placing" | "waitPlace" | "done";

// uint96 max = 2^96 - 1
const UINT96_MAX = (1n << 96n) - 1n;

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
  // "sell" = sell WETH for USDC → zeroForOne depends on sort order
  // "buy"  = buy WETH with USDC → opposite direction
  //
  // On Base  (wethIsCurrency0=true):  sell WETH = zeroForOne=true
  // On Unichain (wethIsCurrency0=false): sell WETH = zeroForOne=false (selling currency1)
  const zeroForOne = chain.wethIsCurrency0
    ? direction === "sell"  // Base: sell WETH (cur0) → true
    : direction === "buy";  // Unichain: buy WETH means sell USDC (cur0) → true

  const spendToken = direction === "sell" ? chain.weth : chain.usdc;

  // ── Hook contract reference ───────────────────────────
  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

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
    error: approveError,
    reset: resetApprove,
  } = useWriteContract();

  const { isSuccess: approveConfirmed, isLoading: approveLoading } =
    useWaitForTransactionReceipt({
      hash: approveTxHash,
    });

  // ── Write: createLimitOrder ───────────────────────────
  const {
    data: createTxHash,
    writeContract: writeCreate,
    error: createError,
    reset: resetCreate,
  } = useWriteContract();

  const { isSuccess: createConfirmed, isLoading: createLoading } =
    useWaitForTransactionReceipt({
      hash: createTxHash,
    });

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
  // User ALWAYS enters "USDC per WETH" in the form.
  // On Base:     stored as-is (currency1/currency0 = USDC/WETH)
  // On Unichain: must INVERT because contract stores currency1/currency0 = WETH/USDC
  const triggerPriceConfig = getTriggerPriceConfig(chain.wethIsCurrency0);

  const parsedTriggerPrice = useMemo(() => {
    try {
      if (!triggerPrice || parseFloat(triggerPrice) <= 0) return null;

      if (triggerPriceConfig.needsInversion) {
        // Unichain: user enters "3500" (USDC/WETH), contract needs WETH/USDC
        // WETH/USDC = 1/3500 ≈ 0.000285714...
        // Store as parseUnits("0.000285714...", 30)
        const userPrice = parseFloat(triggerPrice);
        const invertedPrice = 1 / userPrice;
        // Use high precision string for parseUnits
        const invertedStr = invertedPrice.toFixed(24); // enough precision for 30 decimals
        return parseUnits(invertedStr, triggerPriceConfig.decimals);
      } else {
        // Base: straightforward
        return parseUnits(triggerPrice, triggerPriceConfig.decimals);
      }
    } catch {
      return null;
    }
  }, [triggerPrice, triggerPriceConfig]);

  // Check if amount fits in uint96
  const amountExceedsUint96 = parsedAmount !== null && parsedAmount > UINT96_MAX;

  // Do we already have sufficient allowance?
  const needsApproval =
    parsedAmount !== null &&
    currentAllowance !== undefined &&
    (currentAllowance as bigint) < parsedAmount;

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

  // ── Effect: handle wallet rejections ──────────────────
  useEffect(() => {
    if (approveError) {
      const msg = extractUserMessage(approveError);
      setError(msg);
      setTxStep("idle");
    }
  }, [approveError]);

  useEffect(() => {
    if (createError) {
      const msg = extractUserMessage(createError);
      setError(msg);
      setTxStep("idle");
    }
  }, [createError]);

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

    if (needsApproval) {
      // Step 1: Approve
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
          onError: () => setTxStep("idle"),
        }
      );
    } else {
      // Already approved — skip to create
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
        onError: () => setTxStep("idle"),
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
    txStep === "idle";

  // ── Explorer label ────────────────────────────────────
  const explorerName = chain.chainLabel === "BASE" ? "BaseScan" : "Uniscan";

  // ── Render ────────────────────────────────────────────
  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
      <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-5">
        Create Limit Order
      </h3>

      {/* Direction Toggle */}
      <div className="flex gap-2 mb-4 sm:mb-5">
        <button
          onClick={() => setDirection("sell")}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors ${
            direction === "sell"
              ? "bg-red-500/20 text-red-400 border border-red-500/40"
              : "bg-gray-800 text-gray-400 border border-gray-700 hover:border-gray-600"
          }`}
        >
          Sell WETH → USDC
        </button>
        <button
          onClick={() => setDirection("buy")}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors ${
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
        <label className="block text-xs text-gray-500 mb-1.5">
          Amount ({spendToken.symbol})
        </label>
        <div className="relative">
          <input
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
            disabled={txStep !== "idle"}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                       placeholder-gray-600 focus:outline-none focus:border-gray-500
                       disabled:opacity-50 font-mono"
          />
          {address && userBalance !== undefined && (
            <button
              onClick={() =>
                setAmountIn(formatUnits(userBalance as bigint, spendToken.decimals))
              }
              className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-gray-500
                         hover:text-gray-300 transition-colors"
            >
              MAX: {Number(formatUnits(userBalance as bigint, spendToken.decimals)).toFixed(
                spendToken.decimals === 6 ? 2 : 4
              )}
            </button>
          )}
        </div>
        {amountExceedsUint96 && (
          <p className="text-xs text-red-400 mt-1">
            Exceeds uint96 max (~79B tokens)
          </p>
        )}
      </div>

      {/* Trigger Price Input */}
      <div className="mb-5">
        <label className="block text-xs text-gray-500 mb-1.5">
          Trigger Price (USDC per WETH)
        </label>
        <input
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
          disabled={txStep !== "idle"}
          className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                     placeholder-gray-600 focus:outline-none focus:border-gray-500
                     disabled:opacity-50 font-mono"
        />
      </div>

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
              Order created successfully!
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
            onClick={handleReset}
            className="w-full py-3 rounded-lg bg-gray-800 text-gray-300
                       hover:bg-gray-700 transition-colors text-sm font-medium"
          >
            Place Another Order
          </button>
        </div>
      ) : (
        <button
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
      <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
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

/** Extract a human-readable message from a wagmi/viem error */
function extractUserMessage(err: Error): string {
  const msg = err.message || "";

  if (msg.includes("User rejected") || msg.includes("user rejected")) {
    return "Transaction rejected in wallet";
  }
  if (msg.includes("insufficient funds")) {
    return "Insufficient ETH for gas fees";
  }
  if (msg.includes("reverted")) {
    const match = msg.match(/reason:\s*(.+?)(?:\n|$)/);
    return match ? `Contract reverted: ${match[1]}` : "Transaction reverted by contract";
  }
  if (msg.length > 120) {
    return msg.slice(0, 120) + "…";
  }
  return msg || "Unknown error";
}