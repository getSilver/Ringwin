# CanonicalEvent 字段覆盖率分析

> 对标 Nautilus Trader 规范事件模型 + Binance / Bybit / OKX 三大交易所 API 字段
> 调研日期：2026-08-27 | 数据来源：RingWin 源码 + Nautilus 官方文档 + 交易所 API 文档

---

## 一、RingWin 现有 CanonicalEvent 结构总览

### 1.1 核心层 CanonicalEvent（`trading_shard.zig:492`）

跨策略、适配器、日志与重放的规范不可变消息，schema_version = 4。

```zig
pub const CanonicalEvent = struct {
    version: u16,
    identity: u64,
    source_time: u64,       // 来源时间戳（纳秒）
    receive_time: u64,      // 接收时间戳（纳秒）
    monotonic_time: u64,    // 单调时钟
    wall_time: u64,         // 墙钟时间
    time_presence: TimePresence,  // 位掩码标记哪些时间有效
    payload: Payload,       // 标签联合体，36 种事件类型
};
```

**TimePresence 位掩码**：`source | receive | monotonic | wall | reserved[4bit]`

**Payload 联合体（36 种事件标签）**：

| 类别 | 事件标签 | 载荷类型 |
|------|----------|----------|
| 配置/控制 | `instrument_rules_activated` | `InstrumentRules` |
| | `margin_rules_activated` | `MarginRules` |
| | `account_configuration` | `AccountConfiguration` |
| | `control_command` | `ControlCommand` |
| | `safety_gate_change` | `SafetyGateChange` |
| | `lease_gate_change` | `SafetyGateChange` |
| | `lifecycle_progress` | `LifecycleProgress` |
| | `risk_warning` | `RiskWarning` |
| | `recovery_completed` | void |
| | `version_activation` | `VersionActivationEvent` |
| 账户/余额 | `exchange_balance` | `Balance` |
| | `opening_balance` | `Balance` |
| | `exchange_positions` | void |
| | `economic_account_snapshot` | `EconomicAccountSnapshot` |
| 策略/租赁 | `strategy_activated` | `StrategyActivation` |
| | `primary_lease_granted` | `PrimaryLease` |
| | `risk_lease_granted` | `RiskLease` |
| | `virtual_portfolio_activated` | `VirtualPortfolioActivation` |
| | `portfolio_transfer` | `PortfolioTransfer` |
| | `strategy_cutover_fence` | `StrategyCutoverFence` |
| 行情数据 | `mark_price` | `i64` |
| | `l2_snapshot` | `L2Snapshot` |
| | `l2_delta` | `L2Delta` |
| | `timer` | `TimerRequest` |
| 执行回报 | `execution_report` | `ExecutionReport` |
| | `fill` | `Fill` |
| | `order_dispatch_result` | `DispatchStatus` |
| | `order_reconciliation_result` | `ReconciliationResult` |
| | `external_order_intent` | `OrderIntent` |
| | `strategy_intent_rejected` | `Rejection` |
| OMS 内部 | `oms_intent_group` | `IntentGroup` |
| | `oms_dispatch_batch` | `DispatchBatch` |
| | `oms_execution_report` | `oms_module.ExecutionReport` |
| | `oms_reconciliation_result` | `oms_module.ReconciliationResult` |
| 经济核算 | `economic_fill` | `EconomicFill` |
| | `funding_settlement` | `FundingSettlement` |
| | `venue_forced_execution` | `VenueForcedExecution` |

### 1.2 核心层关键结构体字段

#### ExecutionReport

```zig
pub const ExecutionReport = struct {
    report_id: u64,
    status: ExecutionStatus,  // accepted | partially_filled | filled | canceled
    cumulative_qty: i64,
    remaining_qty: i64,
};
```

#### Fill

```zig
pub const Fill = struct {
    fill_id: u64,
    quantity: i64,
    price_micros: i64,
};
```

#### EconomicFill

```zig
pub const EconomicFill = struct {
    fill_id: u64,
    order_id: u64,
    quantity: i64,
    price_micros: i64,
    fee_micros: i64,
    rebate_micros: i64,
};
```

#### EconomicAccountSnapshot

```zig
pub const EconomicAccountSnapshot = struct {
    snapshot_id: u64,
    usdt_balance_micros: i64,
    spot_asset_quantity: i64,
    swap_position_quantity: i64,
    margin_micros: i64,
};
```

#### VenueForcedExecution

```zig
pub const VenueForcedExecution = struct {
    execution_id: u64,
    side: Side,
    quantity: i64,
    price_micros: i64,
    fee_micros: i64,
    penalty_micros: i64,
};
```

### 1.3 OKX 适配器层 CanonicalEvent（`okx_private_reconciliation.zig:176`）

适配器内部规范化消息，由 AccountCoordinator 桥接进入核心层。

```zig
pub const CanonicalEvent = struct {
    envelope: EventEnvelope,
    payload: EventPayload,
};
```

**EventEnvelope**（`okx_public_market.zig:101`）：

```zig
pub const EventEnvelope = struct {
    source_time_utc_ns: ?u64,
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
    raw_evidence: RawEvidenceRef,           // SHA-256 + stream_sequence
    source_fact_identity: [32]u8,           // 确定性 32 字节身份标识
};
```

**OKX 私有 EventPayload**：

| 标签 | 载荷类型 |
|------|----------|
| `execution_report` | `ExecutionReport` |
| `fill` | `Fill` |
| `exchange_balance_snapshot` | `ExchangeBalanceSnapshot` |
| `exchange_position_snapshot` | `ExchangePositionSnapshot` |
| `exchange_margin_snapshot` | `ExchangeMarginSnapshot` |
| `venue_account_configuration_snapshot` | `VenueAccountConfigurationSnapshot` |

#### OKX ExecutionReport 字段

```zig
pub const ExecutionReport = struct {
    venue_order_id: VenueOrderId,           // u64 枚举
    client_order_id: ClientOrderId,         // FixedText(32)
    instrument: Instrument,
    side: Side,                             // buy | sell
    order_type: OrderType,                  // market | limit | post_only | fok | ioc
    status: ExecutionStatus,                // live | partially_filled | filled | canceled
    quantity: Decimal,
    limit_price: ?Decimal,
    cumulative_filled_quantity: Decimal,
    average_fill_price: ?Decimal,
    request_id: FixedText(32),
    last_trade_id: ?VenueTradeId,
    venue_update_time_utc_ns: u64,
    owned_by_ringwin: bool,
};
```

#### OKX Fill 字段

```zig
pub const Fill = struct {
    venue_trade_id: VenueTradeId,
    venue_bill_id: ?VenueBillId,
    venue_order_id: VenueOrderId,
    client_order_id: ClientOrderId,
    instrument: Instrument,
    side: Side,
    quantity: Decimal,
    price: Decimal,
    fee: Decimal,
    fee_asset: AssetCode,                   // FixedText(16)
    realized_pnl: ?Decimal,
    liquidity: ?Liquidity,                  // maker | taker
    venue_fill_time_utc_ns: u64,
    owned_by_ringwin: bool,
};
```

#### OKX ExchangeBalanceSnapshot

```zig
pub const Balance = struct {
    asset: AssetCode,
    cash_balance: ?Decimal,
    available_balance: ?Decimal,
    equity: ?Decimal,
    frozen_balance: ?Decimal,
    liability: ?Decimal,
    isolated_liability: ?Decimal,
    cross_liability: ?Decimal,
};

pub const ExchangeBalanceSnapshot = struct {
    scope: SnapshotScope,                   // full_rest | ws_reported
    venue_update_time_utc_ns: u64,
    balances: [8]Balance,
    balance_count: u8,
};
```

#### OKX ExchangePositionSnapshot

```zig
pub const Position = struct {
    venue_position_id: VenuePositionId,
    instrument: Instrument,
    margin_mode: MarginMode,                // isolated
    position_side: PositionSide,            // net
    quantity: Decimal,
    average_price: ?Decimal,
    mark_price: ?Decimal,
    liquidation_price: ?Decimal,
    margin: ?Decimal,
    leverage: ?Decimal,
    unrealized_pnl: ?Decimal,
    venue_update_time_utc_ns: u64,
};

pub const ExchangePositionSnapshot = struct {
    scope: SnapshotScope,
    positions: [8]Position,
    position_count: u8,
    includes_zero_positions: bool,
};
```

#### OKX ExchangeMarginSnapshot

```zig
pub const ExchangeMarginSnapshot = struct {
    scope: SnapshotScope,
    venue_update_time_utc_ns: u64,
    total_equity_usd: ?Decimal,
    adjusted_equity_usd: ?Decimal,
    initial_margin_usd: ?Decimal,
    maintenance_margin_usd: ?Decimal,
    margin_ratio: ?Decimal,
    isolated_equity_usd: ?Decimal,
};
```

### 1.4 OKX 公共行情层 CanonicalEvent（`okx_public_market.zig:241`）

```zig
pub const EventPayload = union(enum) {
    instrument_definition_observed: InstrumentDefinitionObserved,
    l2_book_snapshot: L2BookSnapshot,
    l2_book_delta: L2BookDelta,
    reference_price: ReferencePrice,
    funding_rate_published: FundingRatePublished,
    market_data_health_changed: MarketDataHealthChanged,
};
```

---

## 二、三大交易所 API 字段对比

### 2.1 Binance Spot/Futures WebSocket `executionReport`

| 字段 | 含义 | Nautilus 映射 | RingWin 已有 |
|------|------|---------------|-------------|
| `E` | 事件时间(ms) | `ts_event` | ✅ `wall_time` |
| `s` | 交易对 | `instrument_id` | ✅ OKX 层 `instrument` |
| `c` | 客户端订单 ID | `client_order_id` | ✅ `client_order_id` |
| `S` | 买/卖 | `order_side` | ✅ `side` |
| `o` | 订单类型 | `order_type` | ✅ `order_type` |
| `f` | 有效期(GTC/IOC/FOK) | `time_in_force` | ❌ 缺失 |
| `q` | 委托数量 | `quantity` | ✅ `quantity` |
| `p` | 委托价格 | `price` | ✅ `limit_price` |
| `P` | 触发价 | `trigger_price` | ❌ 缺失 |
| `g` | OCO 订单列表 ID | `order_list_id` | ❌ 缺失 |
| `C` | 原始客户端订单 ID | `orig_client_order_id` | ❌ 缺失 |
| `x` | 执行类型(NEW/TRADE/CANCELED...) | `execution_type` | ❌ 缺失 |
| `X` | 订单状态 | `order_status` | ✅ `status` |
| `r` | 拒单原因 | `reject_reason` | ❌ 缺失 |
| `i` | 交易所订单 ID | `venue_order_id` | ✅ `venue_order_id` |
| `l` | 最后成交量 | `last_qty` | ❌ 核心层缺失 |
| `z` | 累计成交量 | `filled_qty` | ✅ `cumulative_filled_quantity` |
| `L` | 最后成交价 | `last_px` | ❌ 核心层缺失 |
| `n` | 累计手续费 | `commission` | ✅ `EconomicFill.fee_micros` |
| `N` | 手续费币种 | `commission_currency` | ❌ 缺失 |
| `T` | 成交时间(ms) | `ts_event` | ✅ `venue_update_time_utc_ns` |
| `t` | 成交 ID | `trade_id` | ✅ `fill_id` / `venue_trade_id` |
| `m` | 是否 Maker | `liquidity_side` | ✅ OKX 层 `liquidity` |
| `O` | 下单时间 | `order_creation_time` | ❌ 缺失 |
| `Z` | 累计成交额 | `cum_quote_qty` | ❌ 缺失 |
| `Y` | 最后成交额 | `last_quote_qty` | ❌ 缺失 |
| `Q` | 委托成交额 | `quote_qty` | ❌ 缺失 |
| `V` | STP 模式 | `stp_mode` | ❌ 缺失 |
| `ps` | 持仓方向(期货) | `position_side` | ✅ OKX 层 `position_side` |
| `cp` | 全平标志 | `close_position` | ❌ 缺失 |
| `AP` | 平均成交价 | `avg_px` | ✅ `average_fill_price` |
| `cr` | 追踪止损偏移 | `trailing_offset` | ❌ 缺失 |
| `wt` | 工作类型 | `working_type` | ❌ 缺失 |
| `ot` | 原始订单类型 | `original_order_type` | ❌ 缺失 |

**覆盖率**：约 16/31 = **52%**

### 2.2 Bybit v5 私有 `order` + `execution` 主题

| 字段 | 含义 | Nautilus 映射 | RingWin 已有 |
|------|------|---------------|-------------|
| `orderId` | 交易所订单 ID | `venue_order_id` | ✅ |
| `orderLinkId` | 客户端订单 ID | `client_order_id` | ✅ |
| `symbol` | 交易对 | `instrument_id` | ✅ |
| `side` | Buy/Sell | `order_side` | ✅ |
| `orderType` | Market/Limit | `order_type` | ✅ |
| `orderStatus` | 订单状态 | `order_status` | ✅ |
| `price` / `qty` | 价格/数量 | `price` / `quantity` | ✅ |
| `leavesQty` | 剩余数量 | `leaves_qty` | ✅ `remaining_qty` |
| `cumExecQty` | 累计成交 | `filled_qty` | ✅ |
| `avgPrice` | 平均成交价 | `avg_px` | ✅ |
| `cumExecFee` | 累计费用 | `commission` | ✅ |
| `feeCurrency` | 费用币种 | `commission_currency` | ❌ 缺失 |
| `createdTime` / `updatedTime` | 时间戳 | `ts_event` | ⚠️ 仅 `venue_update_time` |
| `positionIdx` | 对冲模式索引 | `position_idx` | ❌ 缺失 |
| `reduceOnly` | 仅减仓 | `reduce_only` | ❌ 缺失 |
| `timeInForce` | GTC/IOC/FOK | `time_in_force` | ❌ 缺失 |
| `triggerPrice` / `takeProfit` / `stopLoss` | 算法单字段 | `trigger_price`, `tp`, `sl` | ❌ 缺失 |
| `execId` / `execPrice` / `execQty` | 成交 ID/价格/量 | `trade_id`, `last_px`, `last_qty` | ⚠️ 部分 |
| `execFee` | 单笔费用 | `commission` | ⚠️ 仅累计 |
| `execType` | 执行类型 | `execution_type` | ❌ 缺失 |
| `isMaker` | Maker/Taker | `liquidity_side` | ✅ |
| `execPnl` | 单笔已实现盈亏 | `realized_pnl` | ✅ OKX 层 |
| `seq` | 跨通道全局序列 | — | ❌ 缺失 |
| `closedSize` | 平仓数量 | — | ❌ 缺失 |

**覆盖率**：约 15/25 = **60%**

### 2.3 OKX 私有 `orders` + `fills` 频道

| 字段 | 含义 | Nautilus 映射 | RingWin 已有 |
|------|------|---------------|-------------|
| `ordId` / `clOrdId` | 交易所/客户端订单 ID | `venue_order_id` / `client_order_id` | ✅ |
| `instId` / `instType` | 产品 ID / 类型 | `instrument_id` / `instrument_type` | ✅ |
| `side` / `ordType` | 买卖 / 订单类型 | `order_side` / `order_type` | ✅ |
| `state` | 订单状态 | `order_status` | ✅ |
| `px` / `sz` | 委托价格/数量 | `price` / `quantity` | ✅ |
| `accFillSz` | 累计成交 | `filled_qty` | ✅ |
| `fillPx` / `fillSz` | 最后成交价/量 | `last_px` / `last_qty` | ❌ 核心层缺失 |
| `avgPx` | 平均成交价 | `avg_px` | ✅ |
| `fee` / `feeCcy` | 累计手续费/币种 | `commission` / `commission_currency` | ⚠️ 仅 fee |
| `fillFee` / `fillFeeCcy` | 单笔手续费/币种 | `fill_fee` / `fill_fee_ccy` | ❌ 缺失 |
| `fillPnl` | 单笔已实现盈亏 | `realized_pnl` | ✅ OKX 层 |
| `fillTime` / `tradeId` | 成交时间/成交 ID | `ts_event` / `trade_id` | ✅ |
| `execType` | T/M (taker/maker) | `liquidity_side` | ✅ |
| `rebate` / `rebateCcy` | 返佣/币种 | `rebate` / `rebate_ccy` | ❌ 缺失 |
| `posSide` | net/long/short | `position_side` | ✅ OKX 层 |
| `tdMode` | cross/isolated/cash | `margin_mode` | ✅ OKX 层 |
| `lever` | 杠杆倍数 | `leverage` | ✅ OKX 层 |
| `cTime` / `uTime` | 创建/更新时间 | `order_creation_time` | ❌ 缺失 |
| `category` | normal/liquidation/adl | `order_category` | ❌ 缺失 |

**覆盖率**：约 15/20 = **75%**

---

## 三、Nautilus Trader 规范事件字段（参考标准）

*来源：https://nautilustrader.io/docs/latest/concepts/events/*

### 3.1 OrderFilled（21 字段）

`trader_id`, `strategy_id`, `instrument_id`, `client_order_id`, `venue_order_id`, `account_id`, `trade_id`, `position_id`, `order_side`, `order_type`, `last_qty`, `last_px`, `currency`, `commission`, `liquidity_side`, `info`, `reconciliation`, `event_id`, `ts_event`, `ts_init`

### 3.2 OrderAccepted / OrderCanceled / OrderExpired（各 10 字段）

公共字段 + `venue_order_id`, `account_id`, `reconciliation`

### 3.3 OrderRejected（11 字段）

公共字段 + `account_id`, `reason`, `due_post_only`, `reconciliation`

### 3.4 FillReport（15 字段）

`account_id`, `instrument_id`, `venue_order_id`, `trade_id`, `order_side`, `last_qty`, `last_px`, `commission`, `liquidity_side`, `avg_px`, `report_id`, `ts_event`, `ts_init`, `client_order_id`, `venue_position_id`

### 3.5 AccountState（10 字段）

`account_id`, `account_type`, `base_currency`, `is_reported`, `balances[{currency, total, free, locked}]`, `margins[{currency, total, free, locked}]`, `info`, `event_id`, `ts_event`, `ts_init`

### 3.6 PositionOpened / PositionChanged / PositionClosed（20-28 字段）

`trader_id`, `strategy_id`, `instrument_id`, `position_id`, `account_id`, `opening_order_id`, `closing_order_id`, `entry`, `side`, `signed_qty`, `quantity`, `peak_quantity`, `last_qty`, `last_px`, `currency`, `avg_px_open`, `avg_px_close`, `realized_return`, `realized_pnl`, `unrealized_pnl`, `duration`, `ts_opened`, `ts_closed`, `event_id`, `ts_event`, `ts_init`

---

## 四、字段缺口分析（RingWin vs Nautilus + 交易所）

### 4.1 高优先级缺口

| 缺口类别 | 具体缺失字段 | 来源 | 影响 |
|----------|-------------|------|------|
| **订单生命周期时间戳** | `order_creation_time`, `order_update_time` | 三者均有 | 无法追踪订单从创建到最终状态的完整生命周期 |
| **触发/算法单** | `trigger_price`, `trigger_type`, `take_profit`, `stop_loss`, `trailing_offset` | 三者均有 | 止盈止损单、追踪止损等算法单无法在核心层表达 |
| **持仓方向/对冲模式** | `position_side`(net/long/short), `hedge_mode`, `position_idx` | Bybit, OKX | 多空持仓分离核算缺失 |
| **仅减仓/全平标志** | `reduce_only`, `close_position` | Bybit, OKX | 无法区分减仓单与新开仓单 |
| **保证金/负债明细** | `isolated_margin`, `cross_margin`, `liability`, `interest`, `available_margin` | 三者均有 | 逐币种保证金核算不完整 |
| **账户级保证金** | `total_margin_balance`, `initial_margin`, `maintenance_margin`, `margin_ratio` | OKX, Bybit | OKX 层已有但核心层 `EconomicAccountSnapshot` 仅含 `margin_micros` 单一字段 |
| **单笔已实现盈亏** | `realized_pnl` per fill | Bybit, OKX | OKX 层 Fill 有 `realized_pnl`，但核心层 Fill 无此字段 |
| **手续费币种** | `commission_currency`（独立于报价币） | Binance, Bybit | 核心层 `EconomicFill` 仅用 `fee_micros` 表达，无法区分手续费币种 |

### 4.2 中优先级缺口

| 缺口类别 | 具体缺失字段 | 来源 | 影响 |
|----------|-------------|------|------|
| **费用/返佣粒度** | `fill_fee`, `fill_fee_ccy`, `rebate`, `rebate_ccy`, `fee_rate` | OKX, Bybit | 无法精确追踪单笔费用与返佣 |
| **报价数量/名义金额** | `quote_qty`, `cum_quote_qty`, `notional_usd` | Binance, OKX | 无法按名义金额进行风控计算 |
| **执行类型分类** | `exec_type`(Trade/AdlLiquidation/...) | Bybit, OKX | 无法区分普通成交与自动减仓 |
| **订单分类** | `order_category`(normal/liquidation/adl), `order_list_id`(OCO) | Binance, OKX | 强平单、ADL 单与普通单无法区分 |
| **跨通道排序序列** | `seq`(Bybit), `prev_seq_id`(OKX RPI) | Bybit, OKX | 跨频道事件无法保证全局有序 |
| **算法单追踪** | `algo_id`, `algo_cl_ord_id` | OKX | 条件单生命周期管理缺失 |

### 4.3 低优先级缺口

| 缺口类别 | 具体缺失字段 | 来源 | 影响 |
|----------|-------------|------|------|
| **自成交保护** | `stp_mode`, `smp_type`, `smp_group` | Binance, Bybit | STP 策略配置缺失 |
| **期权专用** | `mark_price`, `index_price`, `iv`, `mark_iv`, `underlying_price` | Bybit, OKX | 如做期权需补充 |
| **时间有效期** | `time_in_force`(GTC/IOC/FOK/FOK) | 三者均有 | 核心层无法表达订单有效期策略 |

### 4.4 核心层 vs OKX 适配器层缺口

**关键发现**：OKX 适配器层（`okx_private_reconciliation.zig`）的字段覆盖度远高于核心层。许多字段已在适配器层实现，但**未桥接到核心层**：

| 字段 | OKX 适配器层 | 核心层 | 差距 |
|------|-------------|--------|------|
| `fill_id` / `venue_trade_id` | ✅ | ✅ `fill.fill_id` | 一致 |
| `venue_order_id` | ✅ | ❌ 核心层 `ExecutionReport` 无此字段 | **需补充** |
| `client_order_id` | ✅ | ❌ 核心层 `ExecutionReport` 无此字段 | **需补充** |
| `instrument` | ✅ | ❌ 核心层通过 `identity` 间接引用 | 架构差异 |
| `side` | ✅ | ❌ 核心层 `ExecutionReport` 无 side | **需补充** |
| `order_type` | ✅ | ❌ 核心层 `ExecutionReport` 无 order_type | **需补充** |
| `quantity` | ✅ | ✅ `cumulative_qty` | 一致 |
| `limit_price` | ✅ | ❌ 核心层无 price 字段 | **需补充** |
| `average_fill_price` | ✅ | ❌ 核心层无 avg_px | **需补充** |
| `fee` / `fee_asset` | ✅ | ⚠️ `EconomicFill.fee_micros` 无币种 | 部分 |
| `realized_pnl` | ✅ Fill 有 | ❌ 核心层 Fill 无 | **需补充** |
| `liquidity` | ✅ Fill 有 | ❌ 核心层 Fill 无 | **需补充** |
| `margin_mode` | ✅ Position 有 | ❌ 核心层无 | **需补充** |
| `position_side` | ✅ Position 有 | ❌ 核心层无 | **需补充** |
| `leverage` | ✅ Position 有 | ❌ 核心层无 | **需补充** |
| `unrealized_pnl` | ✅ Position 有 | ❌ 核心层 `EconomicAccountSnapshot` 无 | **需补充** |
| `liability` / `isolated_liability` / `cross_liability` | ✅ Balance 有 | ❌ 核心层 `Balance` 仅 `cash_micros` | **需补充** |

---

## 五、Nautilus 对标清单

| Nautilus 事件 | RingWin 对应 | 状态 | 备注 |
|---------------|--------------|------|------|
| `OrderAccepted` | `execution_report`(status=accepted) | ✅ 已覆盖 | |
| `OrderFilled` | `fill` + `execution_report`(status=filled) | ⚠️ 部分覆盖 | 缺少 `venue_order_id`, `side`, `order_type`, `last_px`, `currency`, `commission`, `liquidity_side` |
| `OrderCanceled` | `execution_report`(status=canceled) | ✅ 已覆盖 | |
| `OrderExpired` | `execution_report` | ❌ 需补充 | 核心层 `ExecutionStatus` 缺少 `expired` 枚举值 |
| `OrderRejected` | `execution_report` | ❌ 需补充 | 核心层 `ExecutionStatus` 缺少 `rejected` 枚举值；无 `reason` 字段 |
| `OrderDenied` | `strategy_intent_rejected` | ✅ 已覆盖 | 不同架构层 |
| `FillReport` | `fill` | ⚠️ 部分覆盖 | 核心层 Fill 仅 3 字段，需扩展至 ~10 字段 |
| `AccountState` | `exchange_balance` + `exchange_margin_snapshot` | ⚠️ 部分覆盖 | 核心层 `Balance` 仅 `cash_micros`；OKX 层完整 |
| `PositionOpened` | `exchange_positions` | ❌ 需补充 | 核心层为 void 联合体，无字段 |
| `PositionChanged` | — | ❌ 缺失 | 无增量持仓事件类型 |
| `PositionClosed` | — | ❌ 缺失 | 无平仓事件类型 |

---

## 六、已覆盖良好的字段

| 类别 | 已覆盖字段 | 覆盖质量 |
|------|-----------|---------|
| **核心执行** | `venue_order_id`, `client_order_id`, `side`, `status`, `quantity`, `price` | ⚠️ OKX 层完整，核心层部分 |
| **成交回报** | `trade_id`, `quantity`, `price`, `fee`, `liquidity`, `venue_time` | ✅ OKX 层完整 |
| **余额快照** | 多币种 available/frozen/equity/liability | ✅ OKX 层完整 |
| **持仓快照** | 数量、均价、标记价、强平价、保证金、杠杆、未实现盈亏 | ✅ OKX 层完整 |
| **保证金快照** | 权益、初始/维持保证金、保证金率 | ✅ OKX 层完整 |
| **合约规则** | tick_size, lot_size, min/max limits | ✅ 完整 |
| **L2 深度** | 快照 + 增量 + 序列号 | ✅ 完整 |
| **资金费率** | 费率、下次结算时间、结算费率 | ✅ 完整 |
| **时间元数据** | source/receive/monotonic/wall 四维时间戳 + TimePresence 位掩码 | ✅ 超越 Nautilus |
| **原始证据链** | SHA-256 + stream_sequence，审计就绪 | ✅ 超越 Nautilus |
| **市场数据健康** | gap 检测、原因分类、序列追踪 | ✅ 独有优势 |

---

## 七、映射策略建议

### 7.1 核心层 ExecutionReport 扩展

```zig
pub const ExecutionReport = struct {
    // 现有字段
    report_id: u64,
    status: ExecutionStatus,
    cumulative_qty: i64,
    remaining_qty: i64,
    // ---- 新增字段 ----
    venue_order_id: ?u64,                     // 交易所订单 ID
    client_order_id: ?FixedText(32),          // 客户端订单 ID
    side: ?Side,                              // buy | sell
    order_type: ?OrderType,                   // market | limit | ...
    limit_price: ?i64,                        // 委托价格（微价格）
    last_qty: ?i64,                           // 最后成交量
    last_px: ?i64,                            // 最后成交价
    average_fill_price: ?i64,                 // 平均成交价
    commission: ?i64,                         // 手续费
    commission_currency: ?AssetCode,          // 手续费币种
    liquidity_side: ?Liquidity,               // maker | taker
    // 时间戳
    order_creation_time_utc_ns: ?u64,         // 下单时间
    order_update_time_utc_ns: ?u64,           // 更新时间
    // 触发/算法单
    trigger_price: ?i64,                      // 触发价
    trigger_type: ?TriggerType,               // 触发类型
    take_profit: ?i64,                        // 止盈价
    stop_loss: ?i64,                          // 止损价
    trailing_offset: ?i64,                    // 追踪止损偏移
    // 持仓方向
    position_side: ?PositionSide,             // net | long | short
    position_idx: ?u8,                        // 对冲模式索引
    // 标志
    reduce_only: bool,                        // 仅减仓
    close_position: bool,                     // 全平
    time_in_force: ?TimeInForce,              // GTC | IOC | FOK
    // 费用
    quote_quantity: ?i64,                     // 报价数量
    cum_quote_quantity: ?i64,                 // 累计报价数量
    // STP
    stp_mode: ?StpMode,                       // 自成交保护模式
    // 算法单
    algo_id: ?FixedText(32),                  // 算法单 ID
    // 分类
    order_category: ?OrderCategory,           // normal | liquidation | adl
};
```

### 7.2 核心层 Fill 扩展

```zig
pub const Fill = struct {
    // 现有字段
    fill_id: u64,
    quantity: i64,
    price_micros: i64,
    // ---- 新增字段 ----
    venue_trade_id: ?u64,                     // 交易所成交 ID
    venue_order_id: ?u64,                     // 交易所订单 ID
    client_order_id: ?FixedText(32),          // 客户端订单 ID
    side: ?Side,                              // buy | sell
    fee: ?i64,                                // 单笔手续费
    fee_asset: ?AssetCode,                    // 手续费币种
    realized_pnl: ?i64,                       // 单笔已实现盈亏
    liquidity: ?Liquidity,                    // maker | taker
    exec_type: ?ExecType,                     // Trade | AdlLiquidation | ...
    cross_seq: ?i64,                          // 跨通道全局序列
};
```

### 7.3 Adapter 层字段映射表

| RingWin 字段 | Binance 原始字段 | Bybit 原始字段 | OKX 原始字段 |
|--------------|-----------------|---------------|-------------|
| `order_creation_time` | `O` | `createdTime` | `cTime` |
| `order_update_time` | `E` / `T` | `updatedTime` | `uTime` |
| `trigger_price` | `P` | `triggerPrice` | `tpTriggerPx` / `slTriggerPx` |
| `position_side` | `ps`(期货) | 隐含于 `positionIdx` | `posSide` |
| `commission_currency` | `N` | `feeCurrency` | `feeCcy` |
| `fill_fee` | `n`(累计) | `execFee`(单笔) | `fillFee` |
| `rebate` | — | — | `rebate` |
| `cross_seq` | — | `seq` | —(用 `fillTime` 排序) |
| `exec_type` | `x`(executionType) | `execType` | `execType` |
| `reduce_only` | 隐含 | `reduceOnly` | `reduceOnly` |
| `margin_mode` | 账户级 | `marginMode` | `tdMode` |
| `leverage` | — | — | `lever` |
| `time_in_force` | `f` | `timeInForce` | `tdMode`(隐含) |
| `order_category` | — | — | `category` |
| `stp_mode` | `V` | `smpType` | — |

### 7.4 新增事件类型建议

```zig
// Payload 联合体新增
pub const Payload = union(PayloadTag) {
    // ... 现有 36 种 ...
    
    // 持仓增量更新（非全量快照）
    position_update: PositionUpdate,
    
    // 算法单事件
    algo_order_event: AlgoOrderEvent,
    
    // 爆仓预警/强平警告
    liquidation_warning: LiquidationWarning,
    
    // 保证金明细（逐币种）
    account_margin_detail: AccountMarginDetail,
};
```

---

## 八、行动项优先级

| 优先级 | 任务 | 预估工期 | 依赖 |
|--------|------|----------|------|
| **P0** | 核心层 `ExecutionReport` 增加 `venue_order_id`, `client_order_id`, `side`, `order_type`, `limit_price` | 1 天 | 无 |
| **P0** | 核心层 `ExecutionReport` 增加 `trigger_price`, `position_side`, `reduce_only`, `margin_mode`, `leverage` | 1-2 天 | 无 |
| **P0** | 核心层 `Fill` 增加 `realized_pnl`, `liquidity`, `fee`, `fee_asset` | 1 天 | 无 |
| **P0** | `ExecutionStatus` 枚举增加 `expired`, `rejected` | 0.5 天 | 无 |
| **P1** | 核心层 `ExecutionReport` 增加 `commission_currency`, `quote_qty`, `order_creation_time` | 1 天 | P0 |
| **P1** | 核心层 `EconomicAccountSnapshot` 增加 `liability`, `isolated_liability`, `cross_liability` | 1 天 | P0 |
| **P1** | 新增 `PositionUpdate` 增量事件（非全量快照） | 2 天 | P0 |
| **P1** | 新增 `AccountMarginDetail` 事件（逐币种保证金明细） | 2 天 | P0 |
| **P2** | 算法单追踪字段（`algo_id`, `attach_algo_ords`） | 1 天 | P1 |
| **P2** | 跨通道全局序列 `seq` | 0.5 天 | P1 |
| **P2** | 适配器层→核心层字段桥接审计 | 1 天 | P0 |
| **P3** | 期权专用字段（mark_px, iv, underlying_px） | 按需 | — |
| **P3** | 自成交保护字段（stp_mode, smp_type） | 按需 | — |

---

## 九、总结

| 维度 | 覆盖率 | 说明 |
|------|--------|------|
| **核心层 vs Nautilus** | ~40% | 核心层 `ExecutionReport` 仅 4 字段，`Fill` 仅 3 字段 |
| **OKX 适配器层 vs Nautilus** | ~85% | OKX 层字段丰富，但未完全桥接到核心层 |
| **综合覆盖（核心+OKX）** | ~70% | 缺口集中在算法单、生命周期时间戳、持仓增量事件 |
| **Binance 覆盖** | ~52% | 缺少 `time_in_force`, `trigger_price`, `commission_currency` 等 |
| **Bybit 覆盖** | ~60% | 缺少 `reduce_only`, `trigger_price`, `seq` 等 |
| **OKX 覆盖** | ~75% | 覆盖最好，缺少 `cTime/uTime`, `fillFee/fillFeeCcy`, `rebate` |

**核心结论**：

1. **OKX 适配器层字段覆盖度远高于核心层**，需优先审计并桥接适配器层→核心层的字段映射
2. **核心层 `ExecutionReport` 和 `Fill` 是最大缺口**，分别只有 4 和 3 个字段，需要扩展至 20+ 和 10+ 字段
3. **缺失的 30% 字段**主要集中在：订单生命周期时间戳、触发/算法单、持仓方向/对冲模式、粒度费用/返佣/单笔盈亏、逐币种保证金明细
4. **时间元数据和原始证据链是 RingWin 的独有优势**，超越 Nautilus 标准
