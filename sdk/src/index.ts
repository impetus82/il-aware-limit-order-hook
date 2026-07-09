/**
 * il-aware-hook-sdk — typed, framework-agnostic (viem-based) integration surface for
 * ILAwareLimitOrderHook on Base (8453, real Aave vault) and Unichain (130, demo vault).
 *
 * See docs/INTEGRATION.md at the repo root for a quickstart and the full footgun list.
 */

export { hookAbi } from "./abi.js";
export {
  DEPLOYMENTS,
  getDeployment,
  buildPoolKey,
  type ChainDeployment,
  type SupportedChainId,
  type TokenInfo,
} from "./addresses.js";
export {
  MAX_TRIGGER_PRICE,
  UINT96_MAX,
  UINT128_MAX,
  getTriggerPriceConfig,
  encodeTriggerPrice,
  decodeTriggerPrice,
} from "./price.js";
export {
  createLimitOrderParams,
  claimOrderParams,
  depositToVaultParams,
  cancelOrderParams,
  readOrder,
  readUserOrderIds,
  readOrderOwner,
  deriveOrderStatus,
  type CreateLimitOrderInput,
  type SellToken,
  type LimitOrder,
  type OrderStatus,
} from "./orders.js";
