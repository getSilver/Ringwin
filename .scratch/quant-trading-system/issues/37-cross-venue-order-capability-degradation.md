# 定义跨 Venue 订单能力降级语义

Type: grilling
Status: resolved
Blocked by: 16, 29
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

统一 OrderIntent、OrderCommand 与恢复模型面对 OKX、Binance、Gate.io 和 Bitget 在批量下单、原生改单、客户端订单号、TIF、部分成功和限流方面的能力差异时，应采用哪些规范降级、拒绝、拆分、重试及对账语义，才能保持策略行为确定且不破坏幂等和风险预留？

## Answer

### 1. 总原则与能力权限

- CapabilityProfile 按 `Venue + product + environment + account scope` 声明订单身份、变更、批量、限流和对账能力，并通过 ConfigEvent 在明确分片屏障版本化生效。
- 策略只读取规范化的 VenueOrderCapabilities，不读取适配器 endpoint、原始字段或错误码。策略决策记录所观察的能力版本，但最终仍由 RiskDecision 和执行网关复核。
- OrderIntent 永久绑定明确 Venue、ExchangeAccount 和 Instrument；核心不得因能力不足、限流或 Venue 不可用而自动跨所改投。策略观察能力、行情、费用和健康状态后产生面向另一 Venue 的新 OrderIntent。
- OrderIntent 或 IntentGroup 通过 CapabilityDegradationPolicy 显式声明允许的非等价替代。缺失授权、能力 Unknown 或替代路径无法证明时，在生成 OrderCommand 前以稳定原因 `CapabilityUnsupported` 拒绝。
- 适配器只负责忠实编码规范 OrderCommand，不得临场替策略选择 TIF、改价、改单方式、路由或风险语义。
- 实际采用的规范化及降级路径、CapabilityProfile/InstrumentRules/config 版本同时写入 RiskDecision 和 OrderCommand，保证回测、仿真、实盘及重放一致。

### 2. 能力证据与生产准入

- 复用现有证据等级：
  - `Unknown`：证据不足，拒绝使用；
  - `Confirmed/Derived`：可用于设计和 testnet 用例，不能单独授权生产；
  - `TestnetQualified`：目标 Venue、产品、账户模式和 endpoint 已验证成功、拒绝、超时、部分成功、身份、限流及对账行为，可以进入生产 CapabilityProfile；
  - `Unsupported`：明确不支持，除非存在已确认的 CapabilityDegradationPolicy，否则拒绝。
- 生产订单能力必须达到 TestnetQualified。官方文档声明本身不等于生产资格。
- 生产观察与资格证据不一致时立即撤销相应能力、禁止相关新增风险并形成 Adapter/Reconciliation 异常，不能继续依赖旧假设。
- 不增加复杂认证体系；能力记录只保存适用范围、证据版本、测试向量和最近验证结果。

### 3. 不可降级能力

以下 NonDegradableCapability 属于执行安全不变量，缺失时必须拒绝，即使策略显式授权也不能弱化：

- Venue 原生 Post-only；
- VenueReduceOnly；
- Market/可成交订单的价格保护；
- 目标账户模式、持仓模式、保证金模式和逐仓约束。

本地盘口检查不能替代 Post-only，因为检查与撮合之间存在竞态；本地仓位检查不能替代 VenueReduceOnly，因为发送后真实仓位可能变化。普通现货的本地风险限制不得伪装成 VenueReduceOnly。

### 4. 价格、数量与规则版本

- OrderIntent 通过 OrderNormalizationPolicy 选择 `RequireExact` 或 `AllowConservativeNormalization`。
- 合法化发生在 RiskDecision 之前，使用明确 InstrumentRules 版本，并在 RiskDecision 中同时记录原始规格和规范化规格。
- 保守规则固定为：
  - Limit Buy 价格向下取 tick；
  - Limit Sell 价格向上取 tick；
  - Quantity 向下取 step；
  - 不得因规范化增加价格侵略性或风险敞口。
- 规范化后为零、低于最小数量/最小名义金额，或破坏 FOK、Post-only、Reduce-only、保证金及其他风控约束时拒绝。
- Market 的保护价格属于风控与执行安全栅栏，不能被适配器变成无界市场单。
- 适配器不得进行第二次隐式取整。若发送前 CapabilityProfile、InstrumentRules 或相关配置版本已经变化，原命令产生 `NotSent/CapabilityVersionChanged`，释放旧占用并在当前版本下重新风控；网关不得原地重写不可变 OrderCommand。
- 已经 Submitted 的命令不能追回，继续由 ExecutionReport、Fill 和对账解释。

### 5. TIF、Post-only 与有效期

- Venue 不支持或尚未资格化 FOK 时：
  - `RequireFOK`：直接拒绝；
  - `AllowIOCPartial`：允许降级为一次 IOC，任何部分成交均为最终有效经济事实，未成交余量随 IOC 取消。
- FOK → IOC 后不自动重试余量、不拆成多个 IOC，也不自动反向平掉已成交部分；策略观察 ExecutionReport/Fill 后决定是否产生新的 OrderIntent。
- 请求 FOK、实际采用 IOC 及政策版本写入 RiskDecision 和 OrderCommand。
- Post-only 只使用 Venue 原生能力。would-take 拒绝或取消构成该 Order 的确定终态；系统不自动改成普通 Limit、不移动一个 tick，也不沿用原 Order 重发。
- Post-only 结果 Unknown 时先对账，不能因为预计会被拒绝而重发。
- DispatchDeadline 只限制 OrderCommand 最晚首次发送时间。到期前未发送则 `NotSent/DeadlineExpired`；Submitted 或 Live 后不再由该 deadline 自动撤单。
- Venue 订单存活由 TIF 决定。策略需要定时撤单时，通过可重放 TimerEvent 产生新的 Cancel OrderIntent；TimerEvent 到达后仍检查目标 Order/revision，已终态则成为确定性 no-op。

### 6. Amend 规范语义

- Amend OrderIntent 引用目标 Order、OrderRevision、已确认累计成交和 TargetRemainingQuantity；规范 quantity 统一表示希望继续保留的未成交量。
- 适配器根据 CapabilityProfile 把 TargetRemainingQuantity 转换为 Venue 要求的 total quantity 或 remaining quantity。
- 发送前若 OrderRevision、累计成交或订单状态已经变化，命令 `NotSent/StaleOrderRevision` 并基于最新事实重新计算，不能把旧参数发给 Venue。
- 真正原地 native amend 保持同一 Order 和 client order ID，只增加 OrderRevision；回报继续投影到该 Order。
- native amend 增加数量或风险时，发送前先建立增量 RiskReservation；额度不足则拒绝。降低风险时，旧占用保持到 Venue 明确确认新规格后才释放差额。
- native amend 发送后的并发 Fill 是不可变 Venue 事实，不能被改单回报覆盖。
- 首版禁用 amend-failure 自动撤单，例如 OKX `cxlOnFail`。确定改单失败时旧 Order 默认继续存活；策略需要撤单时，在观察失败事实后产生独立 Cancel OrderIntent。
- amend 结果 Unknown 时不能推断旧单保持、已修改或已撤销，必须查询当前订单规格、状态和成交。

### 7. CancelConfirmCreate

- 目标 Venue/产品不支持真正原地 amend 时，只有 CapabilityDegradationPolicy 明确授权才允许 CancelConfirmCreate。
- 规范顺序是：
  1. 为旧 Order 发送 Cancel；
  2. 等待 ExecutionReport 或严格对账证明旧 Order 已终态、不再可能成交；
  3. 应用期间发生的全部 Fill，取得最新仓位、余额、风险和规则版本；
  4. 重新执行风控；
  5. 创建具有新 Order、client order ID、RiskReservation 及 predecessor 关系的替代单。
- PendingCancel 或 Unknown 时禁止发送替代单，不提供先发新单再撤旧单的重叠模式。
- 旧单部分成交后按最新状态重新计算替代数量；原始改单参数不能直接照搬。
- 替代单风控失败时保持“旧单已终态、替代单未创建”的真实结果，不能复活旧单或借用已释放占用。
- 首版暂不调用 Venue 的组合 cancel-replace 或异步撤旧建新 modify；见 Deferred 中的后续资格化入口。

### 8. Order 与 client order ID

- 每个 Order 在整个生命周期只有一个永久内部身份和一个永不复用的 client order ID。
- native in-place amend 保持 Order/client order ID；CancelConfirmCreate 建立新的 Order/client order ID，并记录 predecessor。
- TransportBatch 不改变订单身份。
- client order ID 由稳定内部身份经 Venue 专用、版本化 codec 编码，满足目标字符集和长度；截短必须保留足够碰撞空间并执行本地唯一性检查。
- 即使 Venue 允许终态后复用，系统也不复用。client order ID 用于关联、查询和撤单，但不被视为历史级 exactly-once 键。

### 9. Cancel 范围

- Cancel OrderIntent 精确引用目标 Order/revision；适配器只能使用已经资格化的 client order ID 或 Venue order ID 撤销该订单。
- 缺少 Venue order ID、但能力档案支持 client ID 撤单时可使用 client ID；两种身份均不足时先查询和对账。
- 单笔 Cancel 不能降级成按 Instrument、产品或账户的 cancel-all，因为这会影响其他 StrategyInstance 和 VirtualPortfolio。
- `CancelOpenOrders` 只由具有明确范围的独立 ControlCommand 触发，不能作为普通 Cancel 的回退。
- 多个精确 Cancel 可以进入 TransportBatch，但身份、占用和结果仍逐项独立；部分失败不扩大重试范围。
- Unknown Order 的风险占用持续保留，直到撤单或对账事实证明终态。

### 10. TransportBatch

- TransportBatch 只是传输优化，不是领域事务；每个 OrderCommand、RiskReservation、DispatchAttempt、OrderDispatchResult 和 Unknown 恢复始终独立。
- 策略只产生独立 OrderIntent。IntentGroup 不表达 batch ID、批次成员或“必须同批发送”，策略不得推导原子性、同时到达或批次顺序保证。
- 网关只合并同一 Venue、ExchangeAccount、产品、endpoint 操作类型、GatewaySession 和 CapabilityProfile 版本的命令。
- Cancel、VenueReduceOnly、DeRisk 等安全命令与普通 Submit/Amend 分开组批，不能被普通订单占满批次而延迟。
- 批内按安全优先级、DispatchDeadline、ShardSequence 和 CommandIdentity 稳定排序。
- 只合并已经在队列中的命令，不为凑满 Venue 最大条数额外等待；达到 endpoint 上限、最早 deadline 或当前调度周期即发送。
- 精确批次成员、顺序、逐项限流成本和 DispatchAttempt 写入 OrderDispatchResult。历史重放不重新猜测组批结果。
- 批量接口不可用时拆成单笔发送属于不改变经济语义的传输降级，无需策略授权，但必须保持相同优先级、稳定顺序和期限。
- 批量响应拆成逐项事实。部分成功不回滚成功项；确定失败只释放相应项目；整批响应不明时，所有可能已发送项分别进入 Unknown，能证明未发送的项目才是 NotSent。

### 11. IntentGroup 与部分成功

- IntentGroup 成员具有稳定顺序，但该顺序只用于确定性风控、日志、调度平局和展示，不构成 Venue 执行依赖。
- `Independent`（默认）：各 OrderIntent 独立取得资格和执行；某项失败不阻止或撤销其他成员。
- `CancelRemaining`（显式）：任一确定失败或组期限到达后，停止尚未发送的成员，并为仍存活成员产生确定性 Cancel OrderIntent。
- 任一成员 Unknown 时暂停该组尚未发送成员，保持全部风险占用并先对账；Unknown 不能被当作成功或失败。
- Fill 永不回滚，也不自动反向对冲。策略根据实际 Fill 产生新的 DeRisk/Hedge 意图。
- 如果策略要求“先成交 A，再按实际成交量提交 B”，必须等待 A 的 ExecutionReport/Fill 后产生新的 OrderIntent；首版不建设通用条件依赖图或订单工作流。
- `Independent` 和 `CancelRemaining` 都是 best-effort PartialExecutionPolicy，IntentGroup 永不声称 Venue 原子性。

### 12. 限流与有界调度

- Cancel、VenueReduceOnly/DeRisk 和必要对账使用安全优先级；普通 Submit 和扩大风险的 Amend 优先级最低。
- OrderIntent/OrderCommand 必须有明确有效期。预计能在期限内取得额度时可进入有界等待；否则在 OrderCommand 生成前以 `RateLimitCapacityUnavailable` 拒绝。
- 已生成但未发送的命令等待到期时产生 `NotSent/DeadlineExpired`，释放对应 RiskReservation 和 OrderRate 占用。
- Batch 按 CapabilityProfile 中每项的真实成本计入限流，不能默认整批只消耗一次。
- REST 和 WS 共享额度时使用同一预算，不能切换传输绕过限制。
- 安全优先级不能突破 Venue 限额，也不能无限饿死普通订单。持续容量不足时进入 AdapterDegraded，禁止新增风险并报告原因。
- 429 或其他限流错误只有在能力证据明确证明请求未被受理时才是 NotSent；否则进入 Unknown。

### 13. 发送结果与重试

- 同一个不可变 OrderCommand 可以有多个唯一 DispatchAttempt，但重试权只来自 OrderDispatchResult 和对账证据：
  - `NotSent`：命令未过期、版本仍匹配且 RiskReservation 有效时，可使用同一 OrderCommand/client order ID 和新的 DispatchAttempt 重试；
  - `Submitted`：禁止重试，等待 ExecutionReport、Fill 或对账；
  - `Unknown`：禁止重试，先关闭或隔离旧 GatewaySession 并执行对账；
  - `FoundLive/FoundTerminal`：接受 Venue 事实，不再发送；
  - `ConfirmedAbsent`：满足严格证据门槛及旧会话静止后，才允许同一 OrderCommand/client order ID 建立新 DispatchAttempt；
  - `Unresolved`：保持 Unknown、风险占用及相关新增风险禁令。
- 错误码或 timeout 名称本身不能决定重试。只有 CapabilityProfile 明确证明“请求未受理”时才能产生 NotSent；其余全部按 Unknown。

### 14. ConfirmedAbsent 与对账

一次 404/Not Found、open orders 中缺失或私有 WS 没有回报均不足以证明 ConfirmedAbsent。必须同时满足：

- 原 GatewaySession 已关闭、隔离或证明不可能继续投递旧请求；
- 已等待 CapabilityProfile 资格化的 Venue 可见性延迟，不使用跨 Venue 通用秒数；
- client/native ID 查询覆盖 open orders、近期终态订单和 fills，Batch 必须逐项查询；
- 账户、产品、Instrument、分页、时间范围和历史保留 scope 完整，没有限流截断或数据延迟异常；
- 没有 ExecutionReport、Fill、仓位或余额变化能指向该订单；
- 查询身份、范围、原始响应、观察时点和证据版本写入 OrderReconciliationResult。

任一条件无法证明即为 Unresolved，保持 Unknown 和 RiskReservation。Venue 无法提供足够查询覆盖时，该能力不能为生产恢复提供 ConfirmedAbsent。

### 15. 风险占用生命周期

- 所有降级、改单、批量和恢复路径采用“先覆盖最坏可能结果，明确终态后释放”。
- native amend 增加风险时发送前建立增量占用；降低风险时在 Venue 确认新规格后释放差额。
- CancelConfirmCreate 中旧 Order 占用保持到旧单终态及全部 Fill 处理完成；替代单重新取得独立占用。
- Submitted、PendingCancel 和 Unknown 保留覆盖最坏结果的占用；只有明确终态或严格 ConfirmedAbsent 才释放。
- TransportBatch 每项独立占用，部分失败只释放确定失败项。
- IntentGroup 的 CancelRemaining 只发起撤单，不提前释放成员占用。
- 旧单撤销后替代单失败不能恢复旧占用或旧订单事实。

### 16. 稳定错误语义

- 策略只依赖 CanonicalRejectReason，例如 `CapabilityUnsupported`、`InvalidSpec`、`PostOnlyWouldTake`、`InsufficientMargin`、`RateLimited`、`StaleOrderRevision`、`DeadlineExpired`、`VenueUnavailable` 和 `OtherVenueReject`。
- 原始 Venue 错误码、文本、HTTP/WS 状态及 RawIngressRecord 完整保留，用于诊断、审计和更新映射，但不构成策略接口。
- 同一个原始错误码可能随 endpoint 或产品改变语义，映射必须属于版本化 adapter schema/CapabilityProfile。
- 无法可靠分类时使用 OtherVenueReject 或 Unknown，不能猜成可重试错误。
- CanonicalRejectReason 只描述原因，不授予发送重试权。

### 17. 确定性与同核执行

- VenueOrderCapabilities 通过 ConfigEvent 进入 TradingShard；策略决策记录所观察版本。
- OrderIntent 自描述所需语义、规范化和降级政策，RiskDecision 固定实际采用结果，OrderCommand 固定最终 Venue 目标与规格。
- 历史恢复只重建 Order、占用、DispatchAttempt 和事实投影，不重发历史命令。
- VerificationReplay 使用当时 CapabilityProfile、InstrumentRules、配置和事件顺序重算并比较 RiskDecision/OrderCommand；不得使用当前 Venue 能力重新解释历史决策。
- L2ReplayBacktest 和 SimulatedVenue 使用相同规范能力、降级、部分成功、限流、Unknown 和恢复语义。历史 CapabilityProfile 缺失时运行降级，不能作为生产资格证据。

## Deferred

- 首版暂不使用 Venue 的组合 cancel-replace 或异步撤旧建新 modify 接口，只使用已资格化的真正原地 amend 或本地 CancelConfirmCreate。该能力不是永久排除；真实策略证明两阶段往返和短暂离场不可接受时，可按 `Venue + product + endpoint` 单独研究、testnet 资格化其旧/新订单身份、部分成功、Unknown、限流与风险占用语义后，通过版本化 CapabilityProfile 启用。
- 首版禁用 amend-failure 自动撤单（例如 OKX `cxlOnFail`）。后期只有策略明确需要，并且目标 Venue/产品对确定失败、Unknown、旧单存活和撤单回报的语义已资格化时，才作为独立 CapabilityProfile 能力和显式政策启用。
- 首版不提供重叠式“先发新单再撤旧单”、通用 Smart Order Router、通用条件订单工作流或任意依赖图。真实策略证明必要后应分别建立新决策票，不能作为适配器内部开关加入。

## Comments

- 2026-07-29：基于[建立交易所适配器能力契约](16-exchange-adapter-capabilities.md)和[定义完整事件分类、字段与兼容性契约](29-event-taxonomy-and-schema-compatibility.md)完成逐项设计访谈。
- 2026-07-29：用户确认全部能力授权、不可降级安全约束、TIF、改单、Batch、IntentGroup、订单身份、限流、重试、对账、风险占用和确定性规则。
- 2026-07-29：按用户要求明确记录组合 cancel-replace 与 amend-failure 自动撤单只是首版暂不使用，后期可按证据和 CapabilityProfile 版本资格化启用。
