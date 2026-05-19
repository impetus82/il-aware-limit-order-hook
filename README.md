# ILAwareLimitOrderHook

> **IL-Aware Limit Orders with Auto-Yield** — a Uniswap V4 hook that turns every limit order into a yield-bearing DeFi position, and compensates LPs for impermanent loss from the yield earned.

Submitted to the **[UHI9 — Uniswap Hookathon](https://atrium.academy/uniswap)** · Deployed on **Unichain**

---

<!-- TODO: Add YouTube Demo Video link once recorded -->
> **Demo Video:** _coming soon_

---

## Development Timeline

- **April 2026:** LimitOrderHook v2 deployed on Base + Unichain mainnet
  (prior work, separate repo: [github.com/impetus82/limit-order-hook-v4](https://github.com/impetus82/limit-order-hook-v4))
- **May 17–19, 2026:** ILAwareLimitOrderHook scaffolded as Hookathon
  preparation (pre-competition architecture work — IL rebate engine,
  SimulatedYieldVault, 46-test suite, Unichain mainnet deploy)
- **May 25 – June 11, 2026:** Active Hookathon development period
  (SimulatedYieldVault refinement, testing, demo, final submission)

---

## What It Does

Traditional limit orders on-chain are capital-idle: your tokens sit in a contract earning nothing while you wait for the price to hit your target.

**ILAwareLimitOrderHook** changes this:

1. **Place a limit order** — tokens are held in the hook
2. **Order executes automatically** when a swap moves the pool price through your trigger level
3. **Deposit output to a yield vault** (ERC-4626) — output tokens start earning yield immediately
4. **Claim with IL rebate** — when you withdraw, the hook calculates how much impermanent loss your position suffered and rebates it from the accumulated yield

The result: you never leave money on the table. Every pending order earns yield, and executed orders get partial IL compensation — all without any external oracle.

---

## Architecture

```
User                PoolManager              ILAwareLimitOrderHook
 |                      |                            |
 |-- createLimitOrder() ------------------------------>  mint ERC-721 NFT
 |                      |                            |  register trigger tick
 |                      |                            |
 |-- swap() ------------>|                            |
 |                      |-- afterSwap() ------------->  walk linked list
 |                      |                            |  execute eligible orders
 |                      |                            |  output held in hook
 |                      |                            |
 |-- depositToVault() -------------------------------->  ERC-4626 deposit
 |                      |                            |  shares recorded in order
 |                      |                            |
 |-- claimOrder() ------------------------------------->  redeem vault shares
 |                      |                            |  calculate IL rebate
 |                      |                            |  rebate = min(yield, IL)
 |                      |                            |  burn ERC-721 NFT
 |<------ output + rebate ---------------------------|
```

---

## Key Technical Features

### 1. O(1) Tick Scan via Doubly-Linked List

Instead of scanning a fixed range of ticks on every swap (O(n) regardless of population), the hook maintains a **sorted doubly-linked list of only active ticks** — ticks that actually contain orders.

```
SENTINEL_MIN <-> tick(-500) <-> tick(0) <-> tick(300) <-> SENTINEL_MAX
```

- **O(1) insertion** at the correct sorted position
- **O(1) removal** when a tick's last order is filled or cancelled
- **O(K) scan** per swap where K = number of populated ticks crossed, not total tick range

This means a 10,000-tick price move costs the same as a 1-tick move if there are only 2 active ticks between them.

### 2. Flash Accounting Integration

All token flows use Uniswap V4's native flash accounting (`sync -> transfer -> settle -> take`), ensuring:
- No ERC-20 `transferFrom` overhead during order execution
- Atomic settlement within the PoolManager's unlock context
- Compatibility with V4's transient storage model (Cancun EVM)

### 3. Anti-DoS Graceful Execution

`_executeOrder` returns `bool success` instead of reverting on slippage:

```solidity
// Failed orders emit an event and stay in the bucket for next swap
if (!success) {
    emit OrderExecutionFailed(orderId, "slippage");
    continue; // don't revert the whole swap
}
```

A single toxic order (extreme slippage) cannot block ALL swaps in the pool. This eliminates the critical DoS vector present in naive limit-order hook designs.

Gas metering prevents out-of-gas reverts when many orders queue up:
```solidity
if (gasleft() < GAS_LIMIT_PER_ORDER) break; // resume next swap
```

### 4. Oracle-Free IL Calculation

IL is estimated purely from `sqrtPriceX96` delta — no Chainlink, no TWAP oracle needed:

```
sqrtR  = sqrtPriceCurrent * 1e9 / sqrtPriceEntry
diff   = |sqrtR - 1e9|
IL  ~  liquidity * diff^2 / (2 * 1e9^2)
```

This is the second-order Taylor approximation of the exact IL formula, accurate to ~0.5% for price moves up to +/-50%. It uses only data already available inside the hook from V4's `StateLibrary`.

### 5. ERC-721 Composability

Every limit order is minted as an **ERC-721 NFT** at creation time (`orderId == tokenId`). This enables:
- **Secondary market trading** of pending orders (sell a 2000 USDC/WETH buy order at a discount if you need liquidity now)
- **Access control without `creator` storage** — `ownerOf(orderId)` is always the canonical authority
- **Graceful cleanup** — `_ownerOf(orderId) == address(0)` detects burned (cancelled/claimed) orders without iterating

---

## Who Bears the IL Risk?

**Short answer: nobody is made worse off.**

When a limit order executes in a pool, the executing swap moves the price — that price impact is IL for existing LPs. The order creator also participates in this IL because their output tokens were worth more at the pre-swap price.

This hook addresses that loss with a two-sided mitigation:

| Actor | Without This Hook | With This Hook |
|-------|-------------------|----------------|
| Order creator | Receives output tokens, no yield while waiting | Output earns yield in ERC-4626 vault |
| Order creator after fill | Receives exactly `amountOut`, no IL recovery | Receives `amountOut + min(yield, IL)` |
| LP providing liquidity | Earns fees, suffers full IL from limit executions | IL data available via `lpPositions` for external rebate programs |

The rebate formula `rebate = min(yield, ilAmount)` ensures:
- The creator can never receive **more** than their actual IL (no windfall)
- If `yield >= IL`: creator is fully compensated, keeps any excess yield
- If `yield < IL`: creator keeps all yield, absorbs residual IL — but is **always better off** than without the hook

**The hook never takes a loss.** Vault yield is earned on tokens already owed to the user; the protocol is solvent by construction.

---

## Hook Permissions

All 7 flags are enabled:

| Flag | Bit | Purpose |
|------|-----|---------|
| `afterInitialize` | 12 | Record `lastTick` and `sqrtPriceBaseline` at pool creation |
| `afterAddLiquidity` | 10 | Decode `hookData` to track real LP identity for IL |
| `beforeSwap` | 7 | Passthrough (required for `beforeSwapReturnDelta`) |
| `afterSwap` | 6 | Execute eligible orders, update `lastTick` |
| `beforeSwapReturnDelta` | 3 | Future: dynamic fee hook pathway |
| `afterSwapReturnDelta` | 2 | Enable precise output accounting |
| `afterAddLiquidityReturnDelta` | 1 | Enable LP position recording |

---

## Contract Interface

```solidity
// Place a limit order -- mints ERC-721 NFT to msg.sender
function createLimitOrder(
    PoolKey calldata poolKey,
    uint128 triggerPrice,
    bool zeroForOne,
    uint96 inputAmount
) external returns (uint256 orderId);

// Cancel active order -- burns NFT, refunds input tokens
function cancelOrder(uint256 orderId) external;

// After order fills: deposit output to ERC-4626 vault to earn yield
function depositToVault(uint256 orderId) external;

// Claim filled order output + optional IL rebate from yield
// Burns the ERC-721 NFT
function claimOrder(uint256 orderId, PoolKey calldata poolKey) external;
```

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies
forge install

# Set environment variables
export DEPLOYER_PRIVATE_KEY=0x...
export VAULT_ASSET=0x4200000000000000000000000000000000000006  # WETH on Unichain
```

### Deploy to Unichain

```bash
# Unichain Mainnet
forge script script/DeployHookathon.s.sol:DeployHookathon \
  --rpc-url https://mainnet.unichain.org \
  --broadcast --verify -vvvv

# Unichain Testnet
forge script script/DeployHookathon.s.sol:DeployHookathon \
  --rpc-url $UNICHAIN_TESTNET_RPC_URL \
  --broadcast --verify -vvvv
```

The script automatically:
1. Deploys `SimulatedYieldVault` (ERC-4626 compatible, 3% APY via `block.timestamp`)
2. Mines the CREATE2 salt via `HookMiner` to satisfy all 7 permission flags
3. Deploys `ILAwareLimitOrderHook` at the mined address

### Deployed Addresses

| Network | Contract | Address |
|---------|----------|---------|
| Unichain Mainnet | ILAwareLimitOrderHook | [0x8C19f1641946c662308000bB4E2Eaf684c81d4CE](https://uniscan.xyz/address/0x8C19f1641946c662308000bB4E2Eaf684c81d4CE) |
| Unichain Mainnet | SimulatedYieldVault | [0xceee912C708516624E9aC5581c8FCC93eA8eE79d](https://uniscan.xyz/address/0xceee912C708516624E9aC5581c8FCC93eA8eE79d) |
| Unichain Mainnet | USDC/WETH Pool | PoolId: `0xe1d695d4c147091549aeb6f9e78521a0184a1e7e272a71c12e708c881981f6ba` |

Pool init tx: [0x3a082b9cb10f1c632502396116cf2b62280509f98d68e52a6db12cba6104f5a4](https://uniscan.xyz/tx/0x3a082b9cb10f1c632502396116cf2b62280509f98d68e52a6db12cba6104f5a4)

---

## Testing

```bash
# Run all 46 tests
forge test -vvv

# Unit tests (pure functions, no deployment)
forge test --match-contract ILAwareLimitOrderHookTest -vvv

# Integration tests (full PoolManager + hook lifecycle)
forge test --match-contract ILAwareLimitOrderHookIntegrationTest -vvv

# Gas report
forge test --gas-report
```

**Test coverage:** 46 tests — 46 passing, 0 failing

Key scenarios covered:
- `test_AfterInitialize` — baseline price recorded at pool creation
- `test_ILCalculation_PriceDoubled` — IL approximation accuracy
- `test_YieldRebate_OnClaim` — end-to-end vault yield rebate flow
- `test_ERC721_Claim_After_Transfer` — secondary market: new NFT owner claims filled order
- `testGracefulExecutionOnSlippage` — anti-DoS: failed orders do not block the pool
- `testBatchExecution` — multiple orders executed in a single swap

---

## Project Structure

```
.
|-- src/
|   |-- ILAwareLimitOrderHook.sol       # Main hook contract
|-- script/
|   |-- DeployHookathon.s.sol           # One-shot Unichain deployment
|   |-- HookMiner.sol                   # CREATE2 salt miner
|   |-- AddLiquidityUnichain.s.sol
|   |-- TriggerSwapUnichain.s.sol
|   +-- RecoverPool.s.sol
|-- test/
|   |-- ILAwareLimitOrderHook.t.sol             # Unit tests
|   +-- ILAwareLimitOrderHookIntegration.t.sol  # Integration tests (45 tests)
+-- frontend/                                    # Next.js 16 + wagmi v2
    +-- src/
        |-- components/
        |   |-- OrderList.tsx       # ERC-721 order UI with vault actions
        |   +-- CreateOrderForm.tsx
        +-- config/
            |-- abi.json            # Auto-generated by forge build
            +-- contracts.ts        # Chain addresses, poolKey helpers
```

---

## Tech Stack

- **Uniswap V4** — PoolManager, BaseHook, flash accounting
- **Solidity 0.8.26** — via-IR optimizer, Cancun EVM (transient storage)
- **OpenZeppelin** — ERC-721, ERC-4626 (IERC4626), ReentrancyGuard, SafeERC20
- **Foundry** — forge build / test / script
- **Next.js 16** + **wagmi v2** + **viem** + **RainbowKit** — frontend

---

## License

MIT

---

Built for **UHI9 Uniswap Hookathon** · May 2026
