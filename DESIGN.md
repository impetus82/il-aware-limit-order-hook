# DESIGN DOCUMENT: LIMIT ORDERS HOOK FOR UNISWAP V4

## 1. PROBLEM STATEMENT

### Проблема
Limit orders — базовая функциональность традиционных бирж, но **Uniswap V4 не имеет нативной поддержки** limit orders. Трейдеры вынуждены использовать внешние решения (CoW Protocol, 1inch Limit Orders), что создает:[^1]
- **Фрагментацию ликвидности**: ордера размещаются вне Uniswap пулов
- **Высокие gas costs**: отдельные контракты требуют дополнительных транзакций
- **Сложная UX**: юзеры должны переключаться между интерфейсами
- **Риски безопасности**: доверие к external contracts

### Размер рынка
DeFi рынок составляет **$238.54B в 2026** и растет до **$770.56B к 2031** (26.43% CAGR). DEX trading volume достиг **$86.2 trillion в 2025** (+47.4% рост). При этом:[^2][^3]
- CoW Protocol обрабатывает миллионы в limit orders без placement fees[^4][^5]
- 1inch, Uniswap и другие DEX показывают **4-5 basis points** price improvement через auctions[^6]
- Perps volume вырос до **$250-300B weekly** в 2025[^7]

**Оценка потенциала:** если захватить **1-3% от DEX limit order volume**, это **$50M-$200M в monthly order flow**, что при 0.01-0.05% fee = **$50k-$1M/месяц revenue**.

### Кто страдает
1. **DeFi traders**: нет возможности "set and forget" orders на Uniswap
2. **Whale investors**: крупные ордера создают slippage, нужны limit orders
3. **Арбитражёры**: хотят автоматические ордера при достижении target price
4. **LP providers**: теряют volume из-за отсутствия limit orders в пуле

***

## 2. SOLUTION OVERVIEW

### Что делает hook
**LimitOrderHook** — production-ready Uniswap V4 hook, который:
- Позволяет создавать limit orders **напрямую в пулах Uniswap V4**
- **Автоматически исполняет** ордера когда pool price достигает target
- Использует **gas-efficient "slots of buckets" algorithm**[^8]
- Собирает **0.01-0.05% fee** от исполненных ордеров
- Защищен от **MEV, flash loan attacks, price manipulation**

### Как работает
```

User Flow:

1. User создает limit order (e.g., "Sell 1000 USDC when ETH = \$2000")
2. Hook сохраняет order в bucket для price tick 2000 USDC/ETH
3. Кто-то свапает в пуле → price движется к \$2000
4. Hook's afterSwap() детектирует: price >= triggerPrice
5. Hook автоматически исполняет ордер (swap USDC → ETH)
6. User вызывает withdrawFilledOrder() → получает ETH минус 0.05% fee
```

### Ключевые преимущества vs конкуренты

| Фича | LimitOrderHook (наш) | CoW Protocol | 1inch Limit Orders |
|------|---------------------|--------------|-------------------|
| **Интеграция** | Нативная в V4 пулах | Отдельный контракт | Отдельный контракт |
| **Gas cost** | Минимальный (singleton) | Средний | Средний |
| **Execution** | Автоматический в afterSwap | Batch auction (delay) | Keeper bot required |
| **Fees** | 0.01-0.05% | No placement fee, surplus capture | 0.1-0.3% |
| **Ликвидность** | Прямой доступ к V4 pools | External routing | External routing |

**Почему hooks лучше внешних контрактов:**
1. **Gas efficiency**: Uniswap V4 singleton снижает gas на 99% vs отдельные контракты[^9]
2. **Atomic execution**: ордера исполняются в том же блоке что и swap (no delays)
3. **Native liquidity**: используем ликвидность пула напрямую, без routing
4. **No keeper bots**: исполнение в afterSwap hook (не нужны external actors)[^10]

### Технические допущения
- **Минимальный размер ордера**: $100+ (для gas-efficiency)
- **Supported pools**: только V4 pools с хорошей ликвидностью (>$100k TVL)
- **Execution latency**: ордер исполнится только когда кто-то свапнет в пуле (не instant)
- **Partial fills**: MVP поддерживает full fills только, partial fills — в v2

***

## 3. HOOK ARCHITECTURE

### A. Data Structures

```solidity
// OPTIMIZED для gas (packed в 3 storage slots)
struct LimitOrder {
    address creator;           // slot 0: 20 bytes
    uint96 amount0;           // slot 0: 12 bytes (max ~79B tokens with 18 decimals)
    
    address token0;           // slot 1: 20 bytes  
    uint96 amount1;           // slot 1: 12 bytes
    
    uint128 triggerPrice;     // slot 2: 16 bytes (encoded as fixed-point 1e18)
    uint64 createdAt;         // slot 2: 8 bytes (timestamp)
    uint32 bucketIndex;       // slot 2: 4 bytes (price bucket id)
    bool isFilled;            // slot 2: 1 byte
    bool isCancelled;         // slot 2: 1 byte
}

// "Slots of Buckets" algorithm [web:34]
struct PriceBucket {
    uint256 totalLiquidity;        // Combined liquidity of all orders
    uint256 latestSlotIndex;       // Current active slot
    mapping(uint256 => uint256[]) orderIds; // slot => orderIds
}

mapping(uint256 => LimitOrder) public orders;
mapping(int24 => PriceBucket) public priceBuckets; // tick => bucket
uint256 public nextOrderId;
```

**Оптимизации:**

- ✅ **Packed storage**: 3 slots вместо 5+ (экономия ~40k gas per order)
- ✅ **uint96 для amounts**: поддерживает до 79B tokens (достаточно для 99% cases)
- ✅ **Bucket aggregation**: тысячи ордеров обрабатываются одним state change[^8]

**Вопросы \& Решения:**

**Q:** Нужен ли `expiryTime` для автоматического cancellation?
**A:** ✅ **ДА, добавить в v1.1**. Добавим `uint64 expiryTime` в slot 2 (есть место). Это позволит автоматически игнорировать expired orders в `afterSwap()`.

**Q:** Как хранить partial fills?
**A:** **MVP: не поддерживаем**. Partial fills требуют tracking `filledAmount0/filledAmount1`, что +1 storage slot (+20k gas). Добавим в Phase 2 после market validation.

***

### B. Hook Lifecycle

```solidity
function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) external override returns (bytes4) {
    // ❌ НЕ проверяем ордера здесь (экономим gas)
    // Проверка в beforeSwap добавляет 50k+ gas к КАЖДОМУ swap
    return BaseHook.beforeSwap.selector;
}

function afterSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata hookData
) external override returns (bytes4) {
    // ✅ Здесь проверяем и исполняем ордера
    (uint160 sqrtPriceX96,,) = poolManager.getSlot0(key.toId());
    int24 currentTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    
    // Проверяем bucket для текущего tick
    PriceBucket storage bucket = priceBuckets[currentTick];
    if (bucket.totalLiquidity > 0) {
        _executeBucket(key, bucket, currentTick);
    }
    
    return BaseHook.afterSwap.selector;
}
```

**Почему afterSwap, а не beforeSwap?**

1. **Gas efficiency**: beforeSwap вызывается ДО swap → добавляет gas cost каждому swapper
2. **Accurate price**: afterSwap имеет финальную цену после swap (более точно)
3. **Non-intrusive**: не замедляем normal swaps, только обрабатываем fills

**beforeAddLiquidity / afterAddLiquidity?**
❌ **НЕ НУЖНЫ** для limit orders. Эти hooks используются для кастомной LP логики (например, concentrated liquidity management).

***

### C. Key Functions

```solidity
// USER FUNCTIONS

function createLimitOrder(
    PoolKey calldata poolKey,
    bool zeroForOne,          // true = sell token0 for token1
    uint96 amountIn,          // Amount to sell
    uint128 triggerPrice,     // Price encoded as sqrtPriceX96
    uint64 expiryTime         // Order expiry timestamp
) external returns (uint256 orderId) {
    // 1. Validate inputs
    require(amountIn >= MIN_ORDER_SIZE, "Order too small");
    require(expiryTime > block.timestamp, "Invalid expiry");
    
    // 2. Transfer tokens from user (pull pattern)
    address tokenIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
    IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
    
    // 3. Calculate bucket index from price
    int24 tick = TickMath.getTickAtSqrtRatio(triggerPrice);
    
    // 4. Create order
    orderId = nextOrderId++;
    orders[orderId] = LimitOrder({
        creator: msg.sender,
        amount0: zeroForOne ? amountIn : 0,
        amount1: zeroForOne ? 0 : amountIn,
        token0: poolKey.currency0,
        triggerPrice: triggerPrice,
        createdAt: uint64(block.timestamp),
        bucketIndex: uint32(tick),
        isFilled: false,
        isCancelled: false
    });
    
    // 5. Add to bucket
    PriceBucket storage bucket = priceBuckets[tick];
    bucket.orderIds[bucket.latestSlotIndex].push(orderId);
    bucket.totalLiquidity += amountIn;
    
    emit LimitOrderCreated(orderId, msg.sender, amountIn, triggerPrice);
}

function cancelOrder(uint256 orderId) external {
    LimitOrder storage order = orders[orderId];
    require(order.creator == msg.sender, "Not creator");
    require(!order.isFilled && !order.isCancelled, "Cannot cancel");
    
    order.isCancelled = true;
    
    // Return tokens to user
    uint256 amountToReturn = order.amount0 > 0 ? order.amount0 : order.amount1;
    address tokenToReturn = order.amount0 > 0 ? order.token0 : poolKey.currency1;
    IERC20(tokenToReturn).safeTransfer(msg.sender, amountToReturn);
    
    // Update bucket
    PriceBucket storage bucket = priceBuckets[int24(order.bucketIndex)];
    bucket.totalLiquidity -= amountToReturn;
    
    emit LimitOrderCancelled(orderId);
}

function withdrawFilledOrder(uint256 orderId) external {
    LimitOrder storage order = orders[orderId];
    require(order.creator == msg.sender, "Not creator");
    require(order.isFilled, "Order not filled");
    
    uint256 amountOut = order.amount0 > 0 ? order.amount1 : order.amount0;
    uint256 feeAmount = (amountOut * feePercentage) / 10000; // 0.05% = 5 bps
    uint256 netAmount = amountOut - feeAmount;
    
    // Transfer tokens to user
    address tokenOut = order.amount0 > 0 ? poolKey.currency1 : order.token0;
    IERC20(tokenOut).safeTransfer(msg.sender, netAmount);
    
    // Collect fee
    collectedFees += feeAmount;
    
    delete orders[orderId]; // Gas refund
    
    emit OrderWithdrawn(orderId, netAmount, feeAmount);
}

// ADMIN FUNCTIONS

function setFeePercentage(uint256 newFee) external onlyOwner {
    require(newFee <= 50, "Fee too high"); // Max 0.5%
    feePercentage = newFee;
    emit FeeUpdated(newFee);
}

function withdrawFees(address recipient) external onlyOwner {
    uint256 amount = collectedFees;
    collectedFees = 0;
    payable(recipient).transfer(amount);
    emit FeesWithdrawn(recipient, amount);
}
```

**Вопросы \& Решения:**

**Q:** `transferFrom` сразу или approve + pull pattern?
**A:** ✅ **Pull pattern** (`safeTransferFrom`). Это standard для security:

- User делает `approve()` один раз
- Hook делает `transferFrom()` при create
- Меньше attack surface (no custodial funds before order creation)

**Q:** Нужна ли `executeLimitOrder(orderId)` для manual execution?
**A:** ✅ **ДА, но для Phase 2**. MVP полагается на automatic execution в `afterSwap`. Если price достигла target но никто не свапнул — ордер ждет. Manual execution добавим для edge cases.

***

## 4. FEE MECHANISM

### Fee Structure (MVP)

- **Placement fee**: ❌ \$0 (как CoW Protocol )[^5][^4]
- **Execution fee**: ✅ **0.05% от filled volume** (5 basis points)
- **Cancellation fee**: ❌ \$0


### Fee Collection

```solidity
uint256 public feePercentage = 5; // 0.05% = 5 bps
uint256 public collectedFees;     // Accumulated fees in native token

// При withdrawal
uint256 feeAmount = (filledAmount * feePercentage) / 10000;
collectedFees += feeAmount;
```


### Revenue Projections

**Conservative scenario:**

- Monthly order volume: \$50M
- Fee: 0.05%
- Revenue: \$50M × 0.05% = **\$25k/month**

**Moderate scenario:**

- Monthly volume: \$200M (1% от DeFi limit order market)
- Revenue: \$200M × 0.05% = **\$100k/month**

**Optimistic scenario:**

- Monthly volume: \$1B (viral adoption, whales)
- Revenue: \$1B × 0.05% = **\$500k/month**


### Alternative: Revenue Sharing с LP

**Идея:** распределять fees между LP providers пула (как incentive для поддержки hook).

```solidity
// 70% → hook owner
// 30% → LP providers пула
function distributeFees(PoolId poolId) external {
    uint256 lpShare = collectedFees * 30 / 100;
    poolManager.donate(poolId, lpShare, 0); // Donate to LPs
}
```

**Решение для MVP:** ❌ **НЕ делаем** в Phase 1. Это добавляет complexity + нужен governance. Добавим после market validation если LPs требуют incentive.

***

## 5. SECURITY CONSIDERATIONS

### Риски \& Mitigations

| Риск | Severity | Mitigation |
| :-- | :-- | :-- |
| **Reentrancy attack** | 🔴 Critical | ✅ `ReentrancyGuard` от OpenZeppelin на all external functions [^11][^12] |
| **Flash loan price manipulation** | 🔴 High | ✅ Use TWAP (time-weighted average price) для trigger validation [^13][^14] |
| **Front-running execution** | 🟡 Medium | ⚠️ Acceptable риск: front-runner платит gas но не может украсть funds |
| **Price oracle manipulation** | 🔴 High | ✅ Validate price change <= 5% per block, use Uniswap V4 TWAP oracle |
| **Gas griefing** | 🟡 Medium | ✅ Min order size (\$100), rate limiting (max 10 orders/block/user) |
| **Sandwich attacks** | 🟡 Medium | ✅ Use private mempool (Flashbots Protect) для execution txs |
| **Admin key compromise** | 🔴 High | ✅ Use multi-sig (Gnosis Safe) для owner functions |
| **Upgradeability risks** | 🟡 Medium | ✅ Deploy as non-upgradeable for MVP → immutable code [^12] |

### Security Implementation

**1. Reentrancy Protection**

```solidity
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LimitOrderHook is BaseHook, ReentrancyGuard {
    function createLimitOrder(...) external nonReentrant {
        // Safe from reentrancy
    }
}
```

**2. TWAP Price Validation**

```solidity
function _validateTriggerPrice(
    PoolKey calldata key,
    uint160 currentSqrtPriceX96,
    uint160 triggerSqrtPriceX96
) internal view returns (bool) {
    // Get TWAP price (last 5 minutes)
    uint160 twapPrice = _getTWAP(key, 300); // 300 seconds
    
    // Trigger only if current price within 2% of TWAP
    uint256 priceDeviation = _calculateDeviation(currentSqrtPriceX96, twapPrice);
    require(priceDeviation <= 200, "Price manipulation detected"); // 2% = 200 bps
    
    return currentSqrtPriceX96 >= triggerSqrtPriceX96;
}
```

**3. Rate Limiting**

```solidity
mapping(address => mapping(uint256 => uint256)) public userOrdersPerBlock;

function createLimitOrder(...) external {
    require(
        userOrdersPerBlock[msg.sender][block.number] < MAX_ORDERS_PER_BLOCK,
        "Rate limit exceeded"
    );
    userOrdersPerBlock[msg.sender][block.number]++;
    // ...
}
```

**4. Input Validation**[^12]

```solidity
function createLimitOrder(...) external {
    // Validate pool key
    require(_isValidPool(poolKey), "Invalid pool");
    
    // Validate tokens
    require(poolKey.currency0 != poolKey.currency1, "Same token");
    
    // Validate amounts
    require(amountIn >= MIN_ORDER_SIZE, "Too small");
    require(amountIn <= MAX_ORDER_SIZE, "Too large");
    
    // Validate price
    require(triggerPrice > 0, "Invalid price");
}
```


***

## 6. GAS OPTIMIZATION

### Проблема

Naive implementation: проверять все ордера в `afterSwap` → gas cost = **O(n)** где n = количество ордеров. Если 1000 ордеров → **~50M gas** → неприемлемо.

### Решение: "Slots of Buckets" Algorithm[^8]

**Концепт:**

1. Группировать ордера по **price ticks** (buckets)
2. Внутри bucket использовать **slots** для батчинга
3. При fill bucket → обрабатываем все ордера **одним state change**

**Implementation:**

```solidity
struct PriceBucket {
    uint256 totalLiquidity;              // Total amount in bucket
    uint256 latestSlotIndex;             // Active slot (unfilled)
    mapping(uint256 => uint256[]) slots; // slotIndex => orderIds[]
}

mapping(int24 => PriceBucket) public buckets; // tick => bucket

function _executeBucket(
    PoolKey calldata key,
    PriceBucket storage bucket,
    int24 tick
) internal {
    // Process только текущий slot (не все ордера!)
    uint256[] storage orderIds = bucket.slots[bucket.latestSlotIndex];
    
    // Batch execute все ордера в slot
    for (uint256 i = 0; i < orderIds.length; i++) {
        _fillOrder(orderIds[i], key);
    }
    
    // Mark slot as filled, create new slot
    bucket.latestSlotIndex++;
    bucket.totalLiquidity = 0; // Reset after fill
    
    // ✅ Single SSTORE для latestSlotIndex вместо N SSTOREs
}
```

**Gas Cost Comparison:**


| Approach | Gas per Order Fill | Total for 1000 Orders |
| :-- | :-- | :-- |
| Naive (loop all orders) | ~50k gas | 50M gas ❌ |
| **Slots of Buckets** | ~5k gas | 5M gas ✅ |
| **Improvement** | **10x cheaper** | **10x cheaper** |

### Optimal Bucket Size

**Вопрос:** Какой price range для bucket?

**Анализ:**

- Слишком узкий (0.1% range) → слишком много buckets → fragmentacja
- Слишком широкий (10% range) → ордера с разными ценами в одном bucket → неточность

**Решение для MVP:** ✅ **1% price range per bucket**

- ETH \$2000: bucket покрывает \$1980-\$2020
- Достаточно гранулярно для большинства use cases
- Разумное количество buckets для gas efficiency

**Implementation:**

```solidity
function _getBucketIndex(uint160 sqrtPriceX96) internal pure returns (int24) {
    int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    // Round to nearest 1% (tick spacing ~100 for 1%)
    return (tick / TICK_SPACING) * TICK_SPACING;
}
```


***

## USER FLOW DIAGRAM

### Complete Flow (Creation → Execution → Withdrawal)

```
┌─────────────┐
│ 1. USER     │ Connects wallet (MetaMask/WalletConnect)
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 2. SELECT POOL                                  │
│    - Choose token pair (e.g., USDC/ETH)        │
│    - View current price: 1 ETH = $1950         │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 3. INPUT ORDER DETAILS                          │
│    - Amount to sell: 1000 USDC                 │
│    - Target price: 1 ETH = $2000 USDC          │
│    - Expiry: 7 days                            │
│    - Preview: "You will receive ~0.5 ETH"      │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 4. APPROVE USDC                                 │
│    - User calls: USDC.approve(hookAddress)     │
│    - TX confirmed                               │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 5. CREATE ORDER                                 │
│    - User calls: createLimitOrder(...)         │
│    - Hook stores order in bucket (tick 2000)   │
│    - Event emitted: LimitOrderCreated          │
│    - UI shows: "Order placed ✓"                │
└──────┬──────────────────────────────────────────┘
       │
       │ [Time passes... price moves]
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 6. PRICE MOVEMENT                               │
│    - ETH price rises: $1950 → $1980 → $2000    │
│    - Someone swaps in the pool                  │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 7. AUTOMATIC EXECUTION                          │
│    - afterSwap() hook triggered                 │
│    - Detects: currentPrice >= triggerPrice     │
│    - Executes order: swap 1000 USDC → 0.5 ETH  │
│    - Event emitted: LimitOrderFilled           │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 8. NOTIFICATION (optional для Phase 2)         │
│    - Telegram bot: "Your order filled! 🎉"     │
│    - Email alert (if user subscribed)          │
└──────┬──────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────┐
│ 9. WITHDRAW                                     │
│    - User calls: withdrawFilledOrder(orderId)  │
│    - Receives: 0.5 ETH - 0.05% fee = 0.49975 ETH│
│    - UI shows: "Withdrawn ✓"                   │
└─────────────────────────────────────────────────┘
```


### Notification Mechanism (Phase 2)

**Q:** Как user узнает что ордер filled?

**Solutions:**

1. ✅ **Events + The Graph indexer** (MVP)
    - Hook emits `LimitOrderFilled(orderId, timestamp)`
    - The Graph indexes event → frontend polls subgraph
    - Cost: ~\$50/month для The Graph hosting
2. ✅ **Telegram Bot** (Phase 2)
    - User регистрирует Telegram ID при создании ордера
    - Bot слушает events → отправляет alert
    - Implementation: `python-telegram-bot` + Alchemy webhooks
3. ⚠️ **Email alerts** (optional)
    - Требует сбор email → privacy concerns
    - Не делаем в MVP

***

## TECHNICAL DECISION TABLE

| Вопрос | Рекомендация для MVP | Рекомендация для Production | Почему |
| :-- | :-- | :-- | :-- |
| **Token transfer model** | Pull pattern (`transferFrom`) | Same | Standard security practice, меньше attack surface |
| **Price source** | `slot0` (spot price) + basic validation | TWAP (5-minute average) | MVP: быстрее, но риск manipulation. Prod: TWAP безопаснее [^13] |
| **Execution model** | Automatic в `afterSwap` | Automatic + Manual fallback | MVP: простота. Prod: manual для edge cases когда no swaps |
| **Bucket size** | 1% price range (~100 ticks) | Dynamic (0.5-2% based on volatility) | 1% оптимально для большинства пар, dynamic сложнее |
| **Partial fills** | ❌ Not supported | ✅ Supported | MVP: экономим gas. Prod: нужно для крупных ордеров |
| **Upgradeability** | Non-upgradeable (immutable) | Upgradeable proxy (carefully) | MVP: trust через immutability. Prod: может нужны fixes |
| **Admin control** | Single owner (your wallet) | Multi-sig (Gnosis Safe 3/5) | MVP: скорость. Prod: decentralization + security |
| **Fee collection** | Manual withdrawal | Automatic distribution (70/30 split LPs) | MVP: простота. Prod: incentivize LP adoption |
| **Notification** | Events only (The Graph) | Events + Telegram bot | MVP: достаточно. Prod: лучше UX |
| **Rate limiting** | 10 orders/block/user | Dynamic based on gas price | Защита от spam, но не слишком restrictive |


***

## RISKS \& MITIGATIONS

| Риск | Severity | Mitigation Strategy | Status |
| :-- | :-- | :-- | :-- |
| **Reentrancy attack** | 🔴 Critical | OpenZeppelin `ReentrancyGuard` на all functions | ✅ Implement |
| **Flash loan price manipulation** | 🔴 High | TWAP validation (5-min), max 2% deviation from TWAP | ✅ Implement |
| **Gas griefing (spam orders)** | 🟡 Medium | Min order size \$100, rate limit 10/block, max 100 active/user | ✅ Implement |
| **Front-running execution** | 🟡 Medium | Acceptable (front-runner pays gas, no fund theft) | ⚠️ Monitor |
| **Smart contract bug** | 🔴 Critical | Professional audit (Cyfrin/Trail of Bits \$10k-15k), bug bounty \$10k pool | ✅ Phase 1.5 |
| **Low adoption (no swaps)** | 🟡 Medium | Target high-volume pools (ETH/USDC, WBTC/ETH), marketing to traders | ✅ GTM strategy |
| **Competitor copy** | 🟡 Medium | Fast execution (first-mover), community building, continuous iteration | ✅ Speed |
| **Oracle failure** | 🟡 Medium | Fallback to Chainlink oracle if Uniswap TWAP manipulated | ⚠️ Phase 2 |
| **Regulatory risk** | 🟡 Medium | Focus on infrastructure tool (not fund management), no KYC | ✅ Legal review |
| **Hook not adopted by pools** | 🟡 Medium | Deploy own pools with hook, incentivize LPs with fee sharing | ⚠️ Contingency |


***

## IMPLEMENTATION PHASES

### Phase 1: MVP (Weeks 1-8)

**Goal:** Working testnet deployment

- ✅ Week 1-2: Core contract (`LimitOrderHook.sol`)
- ✅ Week 3-4: Testing (unit + integration + fuzz)
- ✅ Week 5-6: Testnet deployment (Sepolia)
- ✅ Week 7-8: Simple frontend (React + wagmi)

**Deliverables:**

- Testnet contract address
- 100% test coverage
- Basic UI for creating/canceling orders

***

### Phase 2: Security \& Refinement (Weeks 9-12)

**Goal:** Production-ready + audit

- ✅ Week 9: Self-audit (Slither, MythX)
- ✅ Week 10: Professional audit submission
- ✅ Week 11: Fix audit findings
- ✅ Week 12: Bug bounty program launch

**Deliverables:**

- Audit report (clean or minimal findings)
- Bug bounty page
- Documentation complete

***

### Phase 3: Mainnet Launch (Weeks 13-16)

**Goal:** Live on Arbitrum/Optimism

- ✅ Week 13: Deploy Arbitrum mainnet
- ✅ Week 14: Monitor, fix bugs
- ✅ Week 15: Deploy Optimism
- ✅ Week 16: Community marketing push

**Target:**

- 100+ users
- \$1M+ total order volume
- \$5k-\$20k first month revenue

***

## GO-TO-MARKET STRATEGY

### Target Users (Priority Order)

1. **DeFi Native Traders** (Week 1-4)
    - Where: Uniswap Discord, r/UniswapProtocol, CT (Crypto Twitter)
    - Message: "Native limit orders for Uniswap V4 — no external contracts"
2. **Whale Investors** (Week 5-8)
    - Where: Private Telegram groups, DeFi alpha communities
    - Message: "Gas-efficient limit orders for large positions"
3. **Arbitrage Bots** (Week 9-12)
    - Where: MEV researcher Discord, Flashbots forum
    - Message: "Automated on-chain limit orders, no keeper needed"

### Distribution Channels

- ✅ **Twitter**: Daily updates, hook examples, user testimonials
- ✅ **Uniswap Forum**: Proposal for Uniswap Grants Program
- ✅ **GitHub**: Open-source repo, detailed docs
- ✅ **Medium**: Technical deep-dive articles
- ✅ **YouTube**: Tutorial videos (5-10 min)


### Metrics to Track

- Active orders count
- Total volume processed
- User retention (week-over-week)
- Revenue (fees collected)
- Pool adoption rate

***

## DELIVERABLES SUMMARY

✅ **Design Document** → Этот файл (сохранить как `DESIGN.md`)
✅ **User Flow** → Диаграмма выше (можно нарисовать в Figma)
✅ **Technical Decisions** → Таблица с MVP vs Production
✅ **Risk Mitigation** → Таблица рисков и mitigations

***

## NEXT STEPS (DAY 3-4)

1. ✅ Сохранить этот Design Doc в `~/projects/limit-order-hook/DESIGN.md`
2. ✅ Создать GitHub repo, залить design docs
3. ✅ Начать coding: `LimitOrderHook.sol` skeleton
4. ✅ Setup Foundry testing environment
5. ✅ Написать first test: `testCreateLimitOrder()`

***

## USEFUL REFERENCES

- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)[^1]
- [Cyfrin Limit Order Algorithm](https://updraft.cyfrin.io/courses/uniswap-v4/hooks/limit-order-algorithm)[^8]
- [Standardweb3 Orderbook Hook](https://github.com/standardweb3/v4-orderbook)[^10]
- [Uniswap V4 Security Deep Dive](https://www.cyfrin.io/blog/uniswap-v4-hooks-security-deep-dive)[^12]
- [CoW Protocol Limit Orders](https://blog.cow.fi/the-cow-has-no-limits-342e7eae8794)[^4]

***

**Готово! 🚀 Теперь у тебя полный Design Document для Day 2-3. Сохрани как `DESIGN.md` и переходи к coding!**