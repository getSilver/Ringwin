# 冻结纵向闭环验收轨迹与状态摘要

Type: grilling
Status: resolved
Blocked by: none
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

首个可执行交易引擎原型使用哪些固定输入、精确事实序列、初始余额和预期终态，才能无歧义地证明行情、策略、风控、订单、执行、仓位、账本、PnL 和重放已经形成同一个闭环？

## Proposed scope

- 固定一个 Gate.io 形状的 `BTC_USDT` USDT 线性永续合约及版本化 InstrumentRules、MarginRules。
- 固定一个 VirtualPortfolio、一个 ExchangeAccount、初始 USDT 余额和零仓位。
- 示例策略只用于确定性触发一笔订单，不包含 Alpha 或参数框架。
- 冻结 happy path、market gap、risk rejection、Unknown reconciliation、duplicate report 五条输入轨迹。
- 为每条轨迹列出输入事件、预期命令/事实、最终订单状态、双层仓位、账本余额、费用、PnL、风险占用和健康状态。
- 定义不依赖内存地址、哈希表遍历顺序或构建时间的 `StateDigestV1`；实时与重放必须逐事件及最终摘要一致。

## Done when

- 所有初始值、事件顺序和期望结果都能写成机器可读 fixture。
- 对“没有发生”的行为也有断言，例如风险拒绝后不得出现 Venue dispatch。
- 用户确认这些轨迹足以定义首个纵向闭环的完成条件。

## Working decisions

### Fixture isolation

- Happy path、market gap、risk rejection、Unknown reconciliation 和 duplicate report 五条验收轨迹彼此独立运行，不串成一个会相互污染状态的长场景。
- 每条轨迹从同一份固定 Genesis fixture 开始；Genesis 固定身份、规则版本、事件序号起点、账户与投资组合初态。
- 每条轨迹必须可以单独执行、单独封存日志并单独重放；权威验收不依赖其他轨迹先运行。
- 组合 smoke scenario 如后续确有诊断价值可以增加，但不得替代五条独立权威轨迹。

### Genesis representation

- Genesis 不是测试代码直接写入的预构造内存状态，而是一段固定、有序、可编码和可重放的初始化事件前缀。
- 初始化事件依次建立并激活 InstrumentRules、MarginRules、账户/持仓模式、VirtualPortfolio、ExchangeAccount、初始资金和全局风险额度。
- TradingShard 只能通过应用这些事件推导零订单、零仓位、零费用和零 PnL 初态；不得存在实时驱动知道而 ReplayDriver 不知道的隐藏初始化。
- Genesis 应用完成后产生一个基线 StateDigestV1，后续每条独立轨迹从该相同基线继续。

### Genesis economic state

- Genesis 以 USDT 为账本计量资产；ExchangeAccount 的总额与可用额均为 `25,000 USDT`。
- 唯一可交易 VirtualPortfolio 通过初始化资金分配获得 `20,000 USDT`；TreasuryPortfolio 保留 `5,000 USDT`。
- PortfolioBalance 与 TreasuryPortfolio 余额合计必须闭合到 ExchangeAccount 的 `25,000 USDT`，两层余额不得相加形成虚假资产。
- VirtualPortfolio 获得 `10,000 USDT` 的全局初始保证金额度租约；租约是风险约束，不是新的余额或资产。
- Genesis 完成时订单、PortfolioPosition、ExchangePosition、费用、返佣、资金费、RealizedPnL 和 UnrealizedPnL 全部为零。

### Instrument and margin rules

- fixture 使用 Gate.io 字段形状的 `BTC_USDT` USDT 线性永续，账户采用逐仓、单向持仓和 `50x` 杠杆。
- 价格 tick 为 `0.1 USDT`，数量步长为 `1 contract`，合约乘数为 `0.0001 BTC/contract`，初始 mark price 为 `50,000.0 USDT/BTC`。
- 普通成交统一使用 taker fee `0.00075`；费用按既有规则朝增加要求方向取整到微 USDT。
- MarginRules 固定为现有定点保证金原型的三档样本：`500,000 / 1,000,000 / 1,500,000 USDT` 上限，以及对应 IMR、MMR 和 deduction。
- happy path 留在第一档；risk rejection 使用越过 `500,000 USDT` 档位的订单，同时覆盖档位选择、账户杠杆和全局额度约束。

### Happy-path order and fills

- 市场健康后，一个固定 TimerEvent 触发原生示例策略产生唯一买入 OrderIntent：`100 contracts @ limit 50,100.0`。
- 风险准入成功后只形成一个 OrderCommand、一个永久 Order 身份和一个唯一客户端订单号。
- 模拟 Venue 先产生接受事实，再产生 `40 contracts @ 49,900.0` 的部分成交和 `60 contracts @ 50,100.0` 的最终成交；订单最终为完全成交。
- 两笔成交均按 taker fee `0.00075` 计费，费用分别为 `0.149700 USDT` 与 `0.225450 USDT`，合计 `0.375150 USDT`。
- 最终 PortfolioPosition 与 ExchangePosition 都是多仓 `100 contracts = 0.01 BTC`。
- 权威移动加权成本状态为 `PositionQuantity = 100 contracts` 与 `OpenCost = 500.200000 USDT`；由此推导的展示平均价为 `50,020.0 USDT/BTC`。
- 最终 mark price 更新为 `50,200.0`，产生 `UnrealizedPnL = 1.800000 USDT`；没有平仓，所以 `RealizedPnL = 0`。
- TradingFee 不进入 OpenCost。VirtualPortfolio 和 ExchangeAccount 的 USDT 账本余额各自减少 `0.375150 USDT`；TreasuryPortfolio 的 `5,000 USDT` 不变，双层资金继续闭合。

### Internal initial-margin buffer

- 首版验收采用固定规则：`InternalInitialMargin = ceil(VenueInitialMargin × 110%)`；舍入单位为微 USDT，并始终朝增加风险要求的方向取整。
- 该 `10%` 缓冲只施加于 VenueInitialMargin，不再按名义价值叠加另一套安全门槛。
- 下单前的 PortfolioMarginReservation 等于最坏成交价格下的 InternalInitialMargin 加全额预估开仓手续费。
- happy path 的最坏名义价值为 `501.000000 USDT`，VenueInitialMargin 为 `10.020000 USDT`，InternalInitialMargin 为 `11.022000 USDT`，手续费预留为 `0.375750 USDT`，因此下单前总预留为 `11.397750 USDT`。
- 该规则是首版 fixture 的确定性验收基准；以后只能通过版本化风险参数事件调整，不能在实时与重放路径中使用不同的隐式配置。

### Risk-occupancy lifecycle

- 风险占用拆分为 `OpenOrderReservation` 与 `PositionMarginRequirement`，不得用一个含义随订单阶段变化的字段混合表示。
- `OpenOrderReservation` 只覆盖未成交数量对应的 InternalInitialMargin 与预估开仓手续费；每次成交后按剩余数量重算，订单进入终态时必须归零。
- `PositionMarginRequirement` 覆盖已成交仓位，按当前 mark price 和同一 `110%` 内部保证金规则重算；它不是订单预留。
- 实际手续费在成交事实应用时立即入账；已入账手续费不得继续留在 OpenOrderReservation 中形成重复占用。
- 全局额度租约的已用额度等于 `OpenOrderReservation + PositionMarginRequirement`。
- happy path 最终 mark 为 `50,200.0`，仓位名义价值为 `502.000000 USDT`，PositionMarginRequirement 为 `11.044000 USDT`，OpenOrderReservation 为零，因此 `10,000 USDT` 全局额度剩余 `9,988.956000 USDT`。

### Deterministic identities

- fixture 固定 `TradingShardId = 1`、`ExchangeAccountId = 1`、`VirtualPortfolioId = 1`、`TreasuryPortfolioId = 2` 和 `StrategyInstanceId = 1`。
- 五条独立轨迹各自使用固定 TraceId，命名为 `happy-v1`、`market-gap-v1`、`risk-rejection-v1`、`unknown-reconciliation-v1` 和 `duplicate-report-v1`。
- OrderIntentId、OrderCommandId 与 OrderId 由 TradingShard 的本地递增计数器确定；实时执行产生一次后写入事实，重放读取原身份而不重新生成。
- 客户端订单号固定编码为 `RWN-{InstanceEpoch}-{ShardId}-{OrderCounter}`；fixture 使用 `InstanceEpoch = 1`，首单为 `RWN-00000001-01-000000000001`。
- SimVenue 的接受、成交与对账回报 ID 必须由各自 fixture 明确给出。
- 权威身份不得依赖随机 UUID、内存地址、墙钟时间或哈希表遍历顺序；生产重启通过更换持久化 InstanceEpoch 避免客户端订单号冲突。

### Time and authoritative ordering

- ShardSequence 是 TradingShard 内唯一权威处理顺序，从 `1` 开始，对输入事件与同步派生事实严格连续递增。
- 同一输入派生多个事实时按固定模块顺序依次写入；时间戳相同不参与打破平局。
- fixture 的全部时间使用整数纳秒，UTC 基点固定为 `2026-01-01T00:00:00Z`。
- fixture 固定 `MonotonicEpochIdentity = fixture-epoch-1`，单调时间从 `1,000,000,000 ns` 开始。
- Venue 输入显式携带 source_time、receive_time 与 monotonic_time；内部同步派生事实继承触发输入的时间值，并以 ShardSequence 区分先后。
- TimerEvent 的计划及触发单调时点直接写入 fixture；策略不得读取当前系统时间。
- 重放保留原有时间值并按原 ShardSequence 投递，不能重新采样时钟或根据时间戳重排事件。
- 每条轨迹的精确时间值与其事件表一同冻结。

### Happy-path market prelude

- happy path 先应用 `MarkPriceUpdate = 50,000.0`。
- 随后应用 `L2Snapshot(source_seq = 100)`：bid 为 `49,800.0 × 1,000 contracts`，asks 依次为 `49,900.0 × 40` 与 `50,100.0 × 60`。
- 再应用连续的 `L2Delta(prev_seq = 100, source_seq = 101)`，把 bid 更新为 `49,850.0 × 1,000 contracts`。
- 只有完成快照和连续增量后才能产生 `MarketHealthChanged: Initializing → Healthy`。
- 固定 TimerEvent 在 Healthy 之后触发策略下单；Healthy 之前到达的 TimerEvent 不得产生可发送的增仓命令。
- 该盘口的 ask 数量精确支持已确认的两笔成交：`40 @ 49,900.0`，随后 `60 @ 50,100.0`。

### Happy-path authoritative fact order

- happy path 下单后的权威事实严格依次为：TimerEvent；OrderIntent；RiskDecision(Accept)；RiskReservationChanged(Create)；OrderCommand(Submit)；OrderDispatchResult(Submitted)；ExecutionReport(Accepted)。
- 第一笔成交依次产生 `Fill(40 @ 49,900.0)`、`LedgerTransaction(Fee 0.149700)`、`RiskReservationChanged(Rebalance)` 和 `ExecutionReport(PartiallyFilled, cumulative = 40, remaining = 60)`。
- 第二笔成交依次产生 `Fill(60 @ 50,100.0)`、`LedgerTransaction(Fee 0.225450)`、`RiskReservationChanged(Rebalance)` 和 `ExecutionReport(Filled, cumulative = 100, remaining = 0)`。
- 最后应用 `MarkPriceUpdate(50,200.0)`，重算估值与 PositionMarginRequirement。
- Fill 先改变双层仓位、移动加权成本与经济事实，随后 ExecutionReport 确认累计成交状态。
- OrderState、PortfolioPosition、ExchangePosition、余额和 PnL 都是事实的同步派生投影，不为内部字段赋值额外伪造状态事件。
- 日志只保存不可变事实以及必须审计的风险占用变化。

### Genesis event prefix

- Genesis 固定为 11 条权威事件：ConfigEvent 激活 InstrumentRules v1；ConfigEvent 激活 MarginRules v1；VenueAccountConfigurationSnapshot 确认逐仓、单向和 50x；ExchangeBalanceSnapshot 确认 `25,000 USDT` 且无锁定资金；ExchangePositionSnapshot 确认空仓。
- 随后依次应用 LedgerTransaction(OpeningBalance)，把 `25,000 USDT` 默认归属 TreasuryPortfolio；ConfigEvent 激活 VirtualPortfolio；PortfolioTransfer 从 Treasury 向 VirtualPortfolio 分配 `20,000 USDT`；ConfigEvent 激活原生示例 StrategyInstance。
- 最后依次应用 PrimaryLeaseChanged，授予模拟执行权限并使用 `FencingToken = 1`；RiskLeaseChanged 授予 `10,000 USDT` 全局保证金额度。
- Genesis 结束时 `ShardSequence = 11`，市场健康状态为 Initializing，没有订单、成交、仓位、费用或 PnL，并生成五条轨迹共用的基线 StateDigestV1。
- 首版不增加“系统启动”“对象创建完成”等没有独立业务含义的样板事件。

### Market-gap trace

- `market-gap-v1` 从 Genesis 开始并重用 happy path 的 MarkPriceUpdate、`L2Snapshot(source_seq = 100)` 与 `L2Delta(100 → 101)`，使市场先进入 Healthy。
- 随后输入 `L2Delta(prev_seq = 102, source_seq = 103)`；当前期望前序为 `101`，因此确定存在来源序号缺口，该 delta 的盘口更新不得应用。
- 缺口产生 `MarketHealthChanged: Healthy → Gap`。
- 固定 TimerEvent 仍使示例策略产生同一买入 OrderIntent；核心风控必须产生 `RiskDecision(Reject, reason = MarketDataGap)`。
- 该拒绝之后不得产生 RiskReservationChanged、OrderCommand、OrderDispatchResult 或 Order。
- 重同步依次输入新的 `L2Snapshot(source_seq = 200)` 与连续 `L2Delta(200 → 201)`，随后产生 `MarketHealthChanged: Gap → Healthy` 并恢复新增风险资格。
- 轨迹结束时 Rejected OrderIntent 与 RiskDecision 保留为事实，但余额、仓位、费用、PnL 和风险额度与 Genesis 相同。

### Risk-rejection trace

- `risk-rejection-v1` 在 Healthy 市场下由策略提交买入 `100,001 contracts @ limit 50,100.0`。
- 最坏名义价值为 `501,005.010000 USDT`，因此选择第二风险档；VenueInitialMargin 为 `10,020.100200 USDT`，InternalInitialMargin 为 `11,022.110220 USDT`。
- 预估开仓手续费朝增加风险要求方向取整为 `375.753758 USDT`，所需总额度为 `11,397.863978 USDT`，超过 `10,000 USDT` 全局风险额度租约。
- 权威结果为 `RiskDecision(Reject, reason = GlobalRiskLeaseExceeded)`；不再叠加余额不足等第二个权威拒绝原因。
- 拒绝后不得产生 RiskReservationChanged、OrderCommand、OrderDispatchResult 或 Order，经济状态与 Genesis 保持一致。

### Unknown-reconciliation trace

- `unknown-reconciliation-v1` 在 Healthy 市场下提交 happy path 的 `100 contracts @ limit 50,100.0`，风控接受并建立 `11.397750 USDT` OpenOrderReservation。
- 执行网关产生 `OrderDispatchResult(Unknown, reason = TransportOutcomeUnknown)`，OrderState 进入 Unknown；不得重发，原风险预留保持不变。
- 对账使用原客户端订单号查询 SimVenue，产生带固定 VenueOrderId 的 `OrderReconciliationResult(FoundLive)`；同一查询响应随后规范化出 `ExecutionReport(Accepted)`，OrderState 恢复为 Live。
- 轨迹结束时只有一个 Order、一个客户端订单号和一次发送尝试；不得创建替代 Order 或第二个 OrderCommand。
- 最终仓位、余额、费用和 PnL 与 Genesis 相同；OpenOrderReservation 为 `11.397750 USDT`，全局额度剩余 `9,988.602250 USDT`。

### Duplicate-report trace

- `duplicate-report-v1` 重用完整 happy path，但在第一笔部分成交后立即重复输入同一条 Venue 原始回报。
- 原始回报固定规范化为 `FillId = sim-fill-1` 与 `ExecutionReportId = sim-report-partial-1`；重复输入必须保留完全相同的事实身份。
- 重复事实可以进入决策日志并取得新的 ShardSequence，但所有权威投影必须把它确定性处理为 no-op，不产生第二笔 LedgerTransaction，也不再次调整风险预留。
- 重复之后仓位仍为 `40 contracts`，OpenCost 仍为 `199.600000 USDT`，累计手续费仍为 `0.149700 USDT`。
- 随后继续第二笔正常成交，最终经济状态与 happy path 完全一致。
- StateDigestV1 包含最终 ShardSequence，因此该轨迹的最终摘要可以与 happy path 不同，但同一轨迹的实时与重放摘要必须一致。

### StateDigestV1

- StateDigestV1 使用 Zig 标准库 SHA-256，输入为显式版本化的稳定二进制状态编码。
- 编码只使用小端整数与显式比例尺；集合按稳定领域身份排序，不得散列内存布局、指针、哈希表遍历结果、格式化文本或 f64。
- 每应用一条 CanonicalEvent 后都可以计算摘要；验收至少比较 Genesis 基线、逐事件摘要序列和最终摘要。
- 摘要覆盖 ShardSequence、规则/配置版本、市场健康与来源序号、L2 订单簿、mark price、策略游标与计数器、订单身份计数器和待触发 Timer。
- 摘要覆盖 Order/OrderState、ExecutionReport/Fill 幂等集合、PortfolioPosition、ExchangePosition、OpenCost、双层账本余额、费用、RealizedPnL、UnrealizedPnL、RiskLease、OpenOrderReservation、PositionMarginRequirement、Unknown 与对账状态。
- 摘要不覆盖日志文件路径、构建时间、当前系统时间、性能指标、诊断文本、内存地址、原始报文文本或展示缓存。

### Fixture representation

- 首版使用一个 Zig fixture 模块，五条轨迹均表示为编译期常量数组，不增加 JSON/YAML 文件、解析器或独立 fixture schema。
- 每个 TraceStep 只负责注入一个外部/控制事件，或断言一个预期权威事实/状态。
- Price、Quantity、Money、Rate 与时间全部使用携带明确比例尺的整数。
- 预期事实、禁止出现的事实、最终字段值和固定 SHA-256 摘要均须显式写入 fixture。
- SimVenue 行为也由 fixture 步骤驱动，不得隐藏在测试代码的场景名称分支中。
- fixture 只提供输入与预期；所有派生事实必须由真实 TradingShard 核心代码产生。
- 只有非 Zig 工具出现实际消费需求时，才从稳定日志格式导出 fixture，不提前维护第二套源格式。

### Fixture time formula

- UTC 基点固定为 `T0 = 2026-01-01T00:00:00Z`；每个独立注入步骤具有 group_index。
- Genesis 使用 group_index `1…11`；每条独立业务轨迹都从 group_index `12` 重新开始。
- 通常 `source_time = T0 + group_index × 10 ms`，`receive_time = source_time + 1 ms`，`monotonic_time = 1,000,000,000 ns + group_index × 10 ms + 1 ms`。
- 同一输入同步派生的 Intent、风险事实、命令和账务事实继承该输入的三个时间值；同一 Venue 回报产生的 Fill 与 ExecutionReport 也使用同一组时间。
- 重复回报保留原 source_time，但使用新的 receive/monotonic group，以表达同一事实稍后再次到达。
- LedgerTransaction 的 EffectiveTime 来自对应 Fill，RecordedTime 使用该 Fill 的 receive_time。

## Answer

### 1. Authority and isolation

五条 fixture 都从相同的 11-event Genesis 独立运行，分别封存、重放和验收。它们不共享运行时状态，也不能用一个组合场景替代。所有核心输入均为 CanonicalEvent；状态只能由事件应用得到。

### 2. Fixed identities

| Identity | Value |
|---|---|
| TradingShardId | `1` |
| ExchangeAccountId | `1` |
| VirtualPortfolioId | `1` |
| TreasuryPortfolioId | `2` |
| StrategyInstanceId | `1` |
| InstanceEpoch | `1` |
| First client order ID | `RWN-00000001-01-000000000001` |
| MonotonicEpochIdentity | `fixture-epoch-1` |

OrderIntentId、OrderCommandId 与 OrderId 使用分片本地递增计数器；重放读取既有身份，不重新生成。TraceId 分别为 `happy-v1`、`market-gap-v1`、`risk-rejection-v1`、`unknown-reconciliation-v1` 和 `duplicate-report-v1`。

### 3. Fixed product and economic Genesis

| Item | Value |
|---|---|
| Product | Gate-shaped `BTC_USDT` linear USDT perpetual |
| Position/margin mode | one-way / isolated |
| Account leverage | `50x` |
| Tick / quantity step | `0.1 USDT` / `1 contract` |
| Contract multiplier | `0.0001 BTC/contract` |
| Initial mark | `50,000.0 USDT/BTC` |
| Taker fee | `0.00075` |
| ExchangeAccount balance | `25,000.000000 USDT` |
| VirtualPortfolio allocation | `20,000.000000 USDT` |
| TreasuryPortfolio remainder | `5,000.000000 USDT` |
| Global margin RiskLease | `10,000.000000 USDT` |
| Orders/positions/fees/PnL | zero |

MarginRules 使用定点保证金原型已经冻结的三档规则。InternalInitialMargin 固定为向上取整到微 USDT 的 `VenueInitialMargin × 110%`。

### 4. Genesis event table

| ShardSequence | group_index | CanonicalEvent |
|---:|---:|---|
| 1 | 1 | ConfigEvent: activate InstrumentRules v1 |
| 2 | 2 | ConfigEvent: activate MarginRules v1 |
| 3 | 3 | VenueAccountConfigurationSnapshot: isolated, one-way, 50x |
| 4 | 4 | ExchangeBalanceSnapshot: 25,000 USDT, locked 0 |
| 5 | 5 | ExchangePositionSnapshot: empty |
| 6 | 6 | LedgerTransaction: OpeningBalance 25,000 USDT to Treasury |
| 7 | 7 | ConfigEvent: activate VirtualPortfolio |
| 8 | 8 | PortfolioTransfer: Treasury → VirtualPortfolio 20,000 USDT |
| 9 | 9 | ConfigEvent: activate native sample StrategyInstance |
| 10 | 10 | PrimaryLeaseChanged: active, FencingToken 1 |
| 11 | 11 | RiskLeaseChanged: grant 10,000 USDT |

序号 11 后生成共用 Genesis StateDigestV1；市场状态是 Initializing。

### 5. Happy-path event table

| Seq | Group | CanonicalEvent / expected fact |
|---:|---:|---|
| 12 | 12 | MarkPriceUpdate 50,000.0 |
| 13 | 13 | L2Snapshot seq 100 |
| 14 | 14 | L2Delta 100→101 |
| 15 | 14 | MarketHealthChanged Initializing→Healthy |
| 16 | 15 | TimerEvent |
| 17 | 15 | OrderIntent: buy 100 @ 50,100.0 |
| 18 | 15 | RiskDecision Accept |
| 19 | 15 | RiskReservationChanged Create 11.397750 |
| 20 | 15 | OrderCommand Submit |
| 21 | 15 | OrderDispatchResult Submitted |
| 22 | 16 | ExecutionReport Accepted |
| 23 | 17 | Fill `sim-fill-1`: 40 @ 49,900.0 |
| 24 | 17 | LedgerTransaction: fee 0.149700 |
| 25 | 17 | RiskReservationChanged Rebalance |
| 26 | 17 | ExecutionReport `sim-report-partial-1`: cumulative 40, remaining 60 |
| 27 | 18 | Fill `sim-fill-2`: 60 @ 50,100.0 |
| 28 | 18 | LedgerTransaction: fee 0.225450 |
| 29 | 18 | RiskReservationChanged Rebalance |
| 30 | 18 | ExecutionReport Filled: cumulative 100, remaining 0 |
| 31 | 19 | MarkPriceUpdate 50,200.0 |

在序号 25 后，PositionMarginRequirement 为 `4.400000 USDT`，剩余订单的 OpenOrderReservation 为 `6.838650 USDT`。序号 29 后 OpenOrderReservation 为零；序号 31 后 PositionMarginRequirement 为 `11.044000 USDT`。

Happy path 终态：

- OrderState = Filled；PortfolioPosition = ExchangePosition = long 100 contracts。
- PositionQuantity = 100；OpenCost = `500.200000 USDT`；展示平均价 = `50,020.0`。
- TradingFee = `0.375150 USDT`；RealizedPnL = 0；UnrealizedPnL = `1.800000 USDT`。
- VirtualPortfolio ledger balance = `19,999.624850 USDT`；Treasury = `5,000.000000 USDT`；ExchangeAccount ledger balance = `24,999.624850 USDT`。
- RiskLease remaining = `9,988.956000 USDT`；MarketHealth = Healthy；final ShardSequence = 31。

### 6. Market-gap trace

从相同 Genesis 开始：序号 12–15 与 happy path 的健康行情前缀相同。随后：

| Seq | Group | CanonicalEvent / expected fact |
|---:|---:|---|
| 16 | 15 | L2Delta prev 102, seq 103: detected gap, update not applied |
| 17 | 15 | MarketHealthChanged Healthy→Gap |
| 18 | 16 | TimerEvent |
| 19 | 16 | OrderIntent: buy 100 @ 50,100.0 |
| 20 | 16 | RiskDecision Reject: MarketDataGap |
| 21 | 17 | replacement L2Snapshot seq 200 |
| 22 | 18 | L2Delta 200→201 |
| 23 | 18 | MarketHealthChanged Gap→Healthy |

不得出现 RiskReservationChanged、OrderCommand、OrderDispatchResult 或 Order。终态经济数据与 Genesis 相同，最后有效 L2 source sequence 为 201，final ShardSequence = 23。

### 7. Risk-rejection trace

序号 12–15 使用健康行情前缀；group 15 的 TimerEvent 产生买入 `100,001 @ 50,100.0`：

| Calculation | Value |
|---|---:|
| Worst notional | `501,005.010000 USDT` |
| Tier | 2 |
| VenueInitialMargin | `10,020.100200 USDT` |
| InternalInitialMargin | `11,022.110220 USDT` |
| Entry-fee reserve | `375.753758 USDT` |
| Total required | `11,397.863978 USDT` |

序号 16 为 TimerEvent，17 为 OrderIntent，18 为 `RiskDecision(Reject, GlobalRiskLeaseExceeded)`。不得产生 reservation、command、dispatch 或 Order；final ShardSequence = 18，经济状态与 Genesis 相同。

### 8. Unknown-reconciliation trace

序号 12–15 使用健康行情前缀：

| Seq | Group | CanonicalEvent / expected fact |
|---:|---:|---|
| 16 | 15 | TimerEvent |
| 17 | 15 | OrderIntent |
| 18 | 15 | RiskDecision Accept |
| 19 | 15 | RiskReservationChanged Create 11.397750 |
| 20 | 15 | OrderCommand Submit |
| 21 | 16 | OrderDispatchResult Unknown: TransportOutcomeUnknown |
| 22 | 17 | OrderReconciliationResult FoundLive |
| 23 | 17 | ExecutionReport Accepted |

终态只有一个 Order、一个客户端订单号、一个 OrderCommand 和一次发送尝试；OrderState = Live，OpenOrderReservation = `11.397750 USDT`，RiskLease remaining = `9,988.602250 USDT`。余额、仓位、费用和 PnL 与 Genesis 相同。

### 9. Duplicate-report trace

序号 12–26 与 happy path 相同。随后在新的 receive/monotonic group 重复第一笔成交回报，但保留原 source_time：

| Seq | Group | CanonicalEvent / expected fact |
|---:|---:|---|
| 27 | 18 | duplicate Fill `sim-fill-1`: deterministic no-op |
| 28 | 18 | duplicate ExecutionReport `sim-report-partial-1`: deterministic no-op |
| 29 | 19 | Fill `sim-fill-2`: 60 @ 50,100.0 |
| 30 | 19 | LedgerTransaction: fee 0.225450 |
| 31 | 19 | RiskReservationChanged Rebalance |
| 32 | 19 | ExecutionReport Filled |
| 33 | 20 | MarkPriceUpdate 50,200.0 |

序号 28 后仓位仍为 40、OpenCost 仍为 `199.600000 USDT`、累计费用仍为 `0.149700 USDT`，且没有第二笔 LedgerTransaction。最终经济状态与 happy path 完全相同，final ShardSequence = 33。

### 10. StateDigestV1 and fixture acceptance

- Zig fixture 模块保存五组输入步骤、预期事实、禁止事实和终态字段。
- StateDigestV1 对版本化稳定二进制状态编码计算 SHA-256；所有集合按稳定身份排序。
- 实时驱动与 ReplayDriver 必须产生相同的有序事实、逐事件摘要序列和最终摘要。
- 固定摘要十六进制值在实现 fixture 编码时写入验收常量；测试不得在运行时用待测实现自动更新 expected digest。
- 任一账本不闭合、重复经济效果、非法 Venue dispatch、身份变化、序号变化或摘要变化均使验收失败。

## Comments

- 2026-07-29：已认领；开始逐项冻结 fixture 身份、数值、事件顺序、预期事实和 StateDigestV1。
- 2026-07-30：用户最终确认完整验收规范；票据解决。
