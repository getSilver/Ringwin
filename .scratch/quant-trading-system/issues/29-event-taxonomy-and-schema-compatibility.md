# 定义完整事件分类、字段与兼容性契约

Type: grilling
Status: resolved
Blocked by: 06, 07, 09, 10, 11, 13, 15, 16, 17
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

交易核心、交易所适配器、策略 Host、日志与重放之间需要哪些规范事件类别和公共信封字段，内存事件与稳定日志表示如何映射，版本升级、未知字段、旧日志重放及跨版本恢复必须遵守什么兼容性契约？

## Answer

规范领域语言记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### 1. 规范事件边界

- CanonicalEvent 是交易核心、适配器、Strategy Host、日志和重放之间使用的规范不可变消息；一个类型只能属于一个 EventFamily。
- EventFamily 只作为 schema 注册表分类，不建立运行时继承树、Visitor、通用事件框架或全局巨型 union。
- RawIngressRecord 保存交易所原始 WebSocket/REST 帧及接入元数据，不是已经验证和标准化的 CanonicalEvent。
- 状态快照、StrategyCheckpoint、配置、数据集和清单是独立内容寻址制品；事件只保存其身份、版本、哈希和引用，不嵌入完整制品。
- 指标、trace、调试日志、普通健康采样和告警投递结果属于遥测，不进入权威分片决策日志。
- OrderState、余额、仓位、风险剩余额度和运行状态是事件派生投影，不能通过覆盖型事件直接修改。
- SimulatedVenue 产生与真实 Venue 相同的 VenueAccountEvent，通过 FactOrigin 和运行清单隔离，不建立平行的 `Simulated*Event` 类型体系。

### 2. EventFamily 与永久 EventType

`event_type` 是小端 `u16`。`0x0000` 永远非法；每个家族预留 256 个编号。编号发布后永不改变或复用，retired 类型永久占号，新类型只追加到所属家族空闲编号。

| 家族 | EventType |
|---|---|
| MarketEvent | `0x0101 InstrumentDefinitionObserved` |
|  | `0x0102 L2BookSnapshot` |
|  | `0x0103 L2BookDelta` |
|  | `0x0104 MarketTrade` |
|  | `0x0105 ReferencePrice` |
|  | `0x0106 FundingRatePublished` |
| VenueAccountEvent | `0x0201 ExecutionReport` |
|  | `0x0202 Fill` |
|  | `0x0203 ExchangeBalanceSnapshot` |
|  | `0x0204 ExchangePositionSnapshot` |
|  | `0x0205 ExchangeMarginSnapshot` |
|  | `0x0206 VenueAccountConfigurationSnapshot` |
|  | `0x0207 FundingSettlement` |
|  | `0x0208 ExternalTransfer` |
|  | `0x0209 VenueAdjustment` |
|  | `0x020A VenueForcedExecution` |
| StrategyEvent | `0x0301 IntentGroup` |
|  | `0x0302 OrderIntent` |
|  | `0x0303 StrategyCheckpointPublished` |
| RiskEvent | `0x0401 RiskLeaseChanged` |
|  | `0x0402 RiskDecision` |
|  | `0x0403 RiskReservationChanged` |
|  | `0x0404 MarginAdjustment` |
| ExecutionEvent | `0x0501 OrderCommand` |
|  | `0x0502 OrderDispatchResult` |
|  | `0x0503 OrderReconciliationResult` |
| AccountingEvent | `0x0601 LedgerTransaction` |
|  | `0x0602 FundingAllocation` |
|  | `0x0603 ForcedExecutionAllocation` |
|  | `0x0604 PortfolioTransfer` |
| ControlEvent | `0x0701 TimerEvent` |
|  | `0x0702 ConfigEvent` |
|  | `0x0703 ControlCommand` |
|  | `0x0704 VersionActivationEvent` |
|  | `0x0705 PrimaryLeaseChanged` |
|  | `0x0706 FencingTokenAdvanced` |
| OperationalEvent | `0x0801 MarketDataHealthChanged` |
|  | `0x0802 AdapterHealthChanged` |
|  | `0x0803 OverloadStateChanged` |
|  | `0x0804 OperationalModeChanged` |
|  | `0x0805 SafetyGateChanged` |
|  | `0x0806 TradingAuthorizationChanged` |
|  | `0x0807 ReconciliationBreakChanged` |
|  | `0x0808 LifecycleOperationChanged` |
|  | `0x0809 FailoverStateChanged` |
|  | `0x080A StateSnapshotPublished` |

测试事件不得写入生产日志。将来单个家族超过 255 个类型时再分配新编号页，不预建扩展层次。

### 3. 稳定日志容器

全部整数采用小端编码。CRC 使用 CRC32C；CRC 只检测意外损坏，不承担防篡改认证。

#### SegmentHeader v1：64 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: u32 = 0x474C5351` (`QSLG`) |
| 4 | `format_version: u16 = 1` |
| 6 | `header_len: u16 = 64` |
| 8 | `stream_identity: u128` |
| 24 | `schema_registry_id: u128` |
| 40 | `monotonic_epoch_identity: u64` |
| 48 | `first_stream_seq: u64` |
| 56 | `flags: u32 = 0` |
| 60 | bytes `[0,60)` 的 CRC32C |

#### EventEnvelope v1：64 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: u32 = 0x544E5651` (`QVNT`) |
| 4 | `record_len: u32` |
| 8 | `event_type: u16` |
| 10 | `schema_version: u16` |
| 12 | `flags: u32` |
| 16 | `stream_seq: u64` |
| 24 | `source_time_ns: i64` |
| 32 | `receive_time_ns: i64` |
| 40 | `monotonic_time_ns: i64` |
| 48 | `wall_time_utc_ns: i64` |
| 56 | payload CRC32C |
| 60 | bytes `[0,60)` 的 header CRC32C |

v1 flags 只定义 bit 0 `source_time_present` 和 bit 1 `receive_time_present`，其余位必须为零。`monotonic_time` 与 `wall_time_utc` 必须存在。缺失字段由 presence bit 表示，对应编码值规范为零，但业务不能把零解释为真实时间。

`record_len` 包含 64 字节头和 payload，范围为 64 至 1,048,576 字节；单条记录不能跨日志段。活动决策日志不压缩，封存研究副本可在容器外压缩。

#### SegmentFooter v1：32 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: u32 = 0x444E4551` (`QEND`) |
| 4 | `footer_len: u32 = 32` |
| 8 | `record_count: u64` |
| 16 | `last_stream_seq: u64` |
| 24 | reserved，必须为零 |
| 28 | bytes `[0,28)` 的 CRC32C |

封闭段必须具有有效 footer，记录数和最后序号必须匹配。活动段可以没有 footer；恢复只接受最后一条头、payload CRC 和连续序号均完整的记录，并把其后的不完整字节判定为 `TruncatedTail`。中间损坏、CRC 错误或序号缺口必须失败关闭，不能当作可截断尾部。

首版不增加整段 CRC、Merkle tree、日志哈希链或逐事件数字签名。封闭段进入 SourceArchive 时，由 LogStreamManifest 记录完整大小和内容哈希。

### 4. 时间与序号

- `source_time` 是外部来源声明的时间；内部事件缺失。
- `receive_time` 是外部事实首次进入本系统时采集的 UTC 时间；内部事件不伪造接收时间。
- `monotonic_time` 用于本机超时、延迟和顺序诊断，只能在同一 MonotonicEpochIdentity 内相减。
- `wall_time_utc` 是原始运行中事件被记录的审计时间。
- UTC 时间不能用于本地超时、租约期限或事件排序。重放保留全部原时间值并使用虚拟时钟投递 TimerEvent；重放机器当前时间不得进入权威计算。
- EffectiveTime 和 RecordedTime 是账务字段，不能从公共时间戳自动推断。
- PTP/NIC 时间戳只改善时间质量，不改变 schema；时间源、精度和健康状态进入日志/运行清单。

不建立热路径全局序号：

- CaptureSequence 属于持久 RawIngressStream，跨连接重连继续递增。
- SourceSequence 属于明确 Venue、频道/连接和 Instrument 范围，允许 Venue 重置、重复或缺口。
- StreamSequence 在同一 StreamIdentity 中跨日志段、重启和主备切换严格连续且永不重置。
- ShardSequence 是 TradingShard 决策日志中的 StreamSequence。
- StrategySequence 只用于确需跨 DecisionDomain 协调的策略并记录实际合并顺序。
- HostBatchSequence 只用于 Strategy Host IPC 确认和落后检测。
- StrategyCursor 指向已完整处理的最后 ShardSequence，不是新的事件序号。
- OrderRevision 和 DispatchAttempt 是局部领域计数器，不参与其他事件排序。

序号溢出、倒退、重复或无法证明上一提交位置时失败关闭。新流必须获得新 StreamIdentity，不能复用旧身份从 1 开始。

### 5. 身份与因果

- EventIdentity 由 `StreamIdentity + StreamSequence` 组成，标识日志中的事件位置；热路径不生成随机 UUID。
- SourceFactIdentity 标识外部或经济事实本身。重复到达可拥有不同 EventIdentity，但保持相同 SourceFactIdentity，最多改变权威状态一次。
- CorrelationIdentity 从 IntentGroup 或 OrderIntent 的确定性身份派生，关联交易决策链，不表示日志顺序。
- 策略事件引用触发输入、StrategyCursor 和配置版本；RiskDecision 引用 OrderIntent；RiskReservationChanged 引用风险决定或释放原因；OrderCommand 引用意图、风险决定和 reservation。
- OrderDispatchResult 引用准确 OrderCommand 与 attempt。ExecutionReport/Fill 引用 RawIngressRecord，并通过 client order ID/Order 回到原交易链。
- LedgerTransaction 引用唯一经济事实；分配事务还记录所用状态屏障和规则版本。
- 多输入计算记录主要原因、状态屏障和规则版本，不建设任意因果 DAG。
- 因果、相关和领域身份放在具体 payload 中，不扩充全部事件的公共头。
- Venue 无法提供稳定原生 ID 时，适配器必须用版本化规则从可证明稳定的字段建立 SourceFactIdentity；无法可靠标识的账户经济事实进入对账失败关闭。

### 6. v1 payload 公共表示规则

- Price、Quantity、Money 和 Rate 使用明确宽度的定点整数；支持 `i64/u64/i128/u128`，权威字段禁止 `f32/f64`。
- 单位与比例尺由 StableEventSchema 固定，或由事件明确引用的 InstrumentRules、MarginRules、Asset precision 版本确定；禁止依赖解码进程的当前规则。
- 可选字段使用 schema 自己的 presence bitmap；零、空串和空数组不能兼任缺失。
- Venue、Instrument、Asset、ExchangeAccount、VirtualPortfolio、StrategyInstance 等使用稳定整数身份。
- Venue order ID、client order ID、trade ID 等使用带长度的有界字节串，并按适配器能力验证字符集；不假定全部为 UTF-8。
- 每个 schema 在注册表声明最大 payload、数组和字节串长度。解码前检查长度、计数乘法、偏移加法和整数转换溢出。
- 已知 schema 必须验证枚举、精确长度、ID、比例尺、数组排序及领域不变量；通过 CRC 不代表事件有效。
- 外部脏数据在适配器边界失败关闭并产生健康事实；本地日志结构或领域验证失败则停止 SemanticReplay。

### 7. MarketEvent v1

| 类型 | 必需 payload |
|---|---|
| InstrumentDefinitionObserved | source fact、venue/instrument、Venue symbol、产品类型、base/quote/settlement asset、交易状态、规范化 InstrumentRules 内容哈希、观察来源和游标 |
| L2BookSnapshot | source fact、venue/instrument、InstrumentRules 版本、来源会话、首末 SourceSequence、bids、asks、可选 Venue checksum |
| L2BookDelta | source fact、venue/instrument、InstrumentRules 版本、来源会话、前序/首末 SourceSequence、updates、可选 Venue checksum |
| MarketTrade | source fact、venue/instrument、InstrumentRules 版本、可选 Venue trade ID、price、quantity、可选 aggressor side |
| ReferencePrice | source fact、venue/instrument、InstrumentRules 版本、Mark/Index 类型、price |
| FundingRatePublished | source fact、venue/instrument、MarginRules 版本、rate、适用区间、结算时点 |

`BookLevel = { price: i64, quantity: u64 }`。`BookUpdate = { side, action: Set/Delete, price: i64, quantity: u64 }`。

Snapshot 买盘严格降序、卖盘严格升序，同侧价格唯一。Delete 的规范 quantity 为零，Set 必须大于零。Delta 必须保存 Venue 声明的完整 SourceSequence 区间。BBO、中间价、深度、K 线和指标是派生数据，不建立第二套权威事件；Gap/Stale 属于 OperationalEvent。

Venue 观察规则先记录为事实；用于交易的 InstrumentRules/MarginRules 必须经 ConfigEvent 在事件屏障生效。

### 8. VenueAccountEvent v1

所有类型必须携带 `FactOrigin = RealVenue | SimulatedVenue`。RealVenue 记录 Production/Testnet；SimulatedVenue 记录 SimulationRunIdentity 和 CalibrationProfile/SimulationScenario 版本。

| 类型 | 必需 payload |
|---|---|
| ExecutionReport | source fact、raw ingress ref、venue/account、client order ID、可选 Venue order ID、Order、revision、报告状态、累计成交、剩余量、可选平均价、稳定原因、来源游标 |
| Fill | source fact、raw ingress ref、venue/account、Order、VirtualPortfolio、Instrument、可选 Venue fill ID、side、price、quantity、liquidity role、charges、EffectiveTime |
| ExchangeBalanceSnapshot | source fact、venue/account、scope、来源游标、as-of time、balances |
| ExchangePositionSnapshot | source fact、venue/account、scope、来源游标、as-of time、账户/持仓模式、positions |
| ExchangeMarginSnapshot | source fact、venue/account、MarginModel、MarginRules 版本、来源游标、as-of time、margin entries |
| VenueAccountConfigurationSnapshot | source fact、venue/account、来源游标、as-of time、持仓模式、保证金模式、杠杆及自动追加保证金设置 |
| FundingSettlement | source fact、raw ingress ref、venue/account、Instrument、settlement asset、实际有符号 amount、Venue settlement ID、rate、mark price、MarginRules 版本、EffectiveTime |
| ExternalTransfer | source fact、venue/account、Venue transfer ID、方向、asset、amount、状态、可选对端/链上引用、EffectiveTime |
| VenueAdjustment | source fact、venue/account、类型、asset 或 Instrument、有符号 amount/quantity、Venue reason、EffectiveTime |
| VenueForcedExecution | source fact、raw ingress ref、venue/account、Instrument、类型、side、price、quantity、RealizedPnL、charges、MarginRules 版本、EffectiveTime |

`Charge = { Fee/Rebate/Penalty, asset_id, signed_amount: i128 }`。余额、仓位及保证金集合元素分别明确总额/可用/锁定、方向数量/可选 Venue 成本、scope/结算资产/初始与维持保证金/风险档位/可选强平价。

Snapshot 集合必须排序、唯一并声明完整 scope；局部查询不能伪装成完整快照。Snapshot 是 Venue 状态事实，不是覆盖本地投影的命令。

ExecutionReport 与 Fill 分离；同一原始回报可以规范化出两条事件，但各自有稳定幂等身份。普通 Fill 必须关联 Order；VenueForcedExecution 不得伪造 Order、OrderIntent 或 OrderCommand。

### 9. StrategyEvent v1

| 类型 | 必需 payload |
|---|---|
| IntentGroup | group identity、StrategyInstance、VirtualPortfolio、触发事件、StrategyCursor、决策序号、策略/参数/配置版本、有序 intent identity、部分执行政策、有效期限 |
| OrderIntent | intent identity、可选 group/组内序号、strategy/portfolio/account/venue/instrument、触发事件、cursor、动作、目标 Order、OrderSpec、配置/规则版本、有效期限、CorrelationIdentity |
| StrategyCheckpointPublished | checkpoint identity、StrategyInstance、StrategyCursor、策略/参数/StateSchemaVersion、内容长度/哈希、稳定存储引用 |

Submit OrderSpec 包含 side、Market/Limit、quantity、可选 price、TIF、post-only 和策略请求的 PortfolioReduceOnly；Cancel 引用目标 Order/revision；Amend 引用目标并只携带明确替换字段。

首版 Venue 条件单、网格和 TWAP 由策略产生普通 OrderIntent，不新增原生 OrderSpec。没有意图的策略决策不创建事件；它由输入重放和 checkpoint/cursor 证明。

### 10. RiskEvent v1

| 类型 | 必需 payload |
|---|---|
| RiskLeaseChanged | lease identity/version、动作、DecisionDomain、ExchangeAccount、适用范围、额度内容、原因、生效/到期单调时间与 epoch |
| RiskDecision | decision identity、OrderIntent、Accept/Reject、稳定原因、lease/rules/config 版本、市场与组合状态屏障、规范化订单规格、计算摘要 |
| RiskReservationChanged | reservation identity、动作、OrderIntent/Order、portfolio/account、lease 版本、状态屏障、components、原因引用 |
| MarginAdjustment | adjustment identity、资金所有者、account/instrument/settlement asset、有符号金额、前后 MarginBuffer、MarginRules 版本、原因引用 |

`ReservationComponent = { Cash/Margin/Exposure/FeeBuffer/OrderRate, asset_or_instrument, signed_amount_or_units }`。

Reject 不建立 reservation；Accept 必须由同一事件序列中的 RiskReservationChanged 闭合。释放必须引用 Fill、终态回报、撤单对账或租约处理事实。计算摘要保存权威输入与结果，不保存调试 trace。

### 11. ExecutionEvent v1

| 类型 | 必需 payload |
|---|---|
| OrderCommand | command identity/kind、intent/risk/reservation、Order、venue/account/instrument、client order ID、revision、最终 OrderSpec、两种 ReduceOnly、RiskLease/PrimaryLease、FencingToken、期限、CorrelationIdentity |
| OrderDispatchResult | OrderCommand、DispatchAttempt、GatewaySessionIdentity、非敏感 credential identity、FencingToken、NotSent/Submitted/Unknown、提交单调时间、稳定原因、请求内容哈希 |
| OrderReconciliationResult | identity、Order、查询目标/覆盖范围、ObservationCredential identity、原始响应引用、观察时点、FoundLive/FoundTerminal/ConfirmedAbsent/Unresolved、可选 Venue 摘要 |

client order ID 必须在任何发送尝试前进入 OrderCommand。同一 revision 可以有多个唯一 attempt。Submitted 只表示交给传输路径，不代表 Venue 接受；只有 ExecutionReport/Fill 能证明外部结果。

请求哈希覆盖真正发送的规范 method/path/body，但排除 SecretMaterial 和签名值。ConfirmedAbsent 必须满足适配器能力契约的查询覆盖，单次查不到不等于不存在。Python Host 不能填写 risk、lease、client order ID、fencing 或 gateway 字段。

### 12. AccountingEvent v1

| 类型 | 必需 payload |
|---|---|
| LedgerTransaction | transaction identity、账务类型、唯一源事实、ExchangeAccount、EffectiveTime、RecordedTime、规则版本、postings、可选原事务 |
| FundingAllocation | identity、FundingSettlement、状态屏障、规则版本、allocation lines、Treasury 尾差、闭合总额 |
| ForcedExecutionAllocation | identity、VenueForcedExecution、执行前屏障、规则版本、allocation lines、Suspense 未归属部分、闭合总额 |
| PortfolioTransfer | identity、ExchangeAccount、来源/目标 VirtualPortfolio、Asset、amount、EffectiveTime、ControlCommand/业务来源 |

`LedgerPosting = { owner_kind, owner_id, ledger_account, asset_or_instrument_unit, signed_amount: i128 }`。同一计量单位必须精确平衡，不同 Asset 不能互抵。

冲正事务引用原事务并逐 posting 反向，替代事务另行追加。手续费、返佣、成交、资金费及 Venue 调整均由源事实确定性生成 LedgerTransaction，不另建余额事件。RealizedPnL 是分类投影；UnrealizedPnL/ValuationSnapshot 不改变权威账本。

### 13. ControlEvent v1

| 类型 | 必需 payload |
|---|---|
| TimerEvent | timer identity、拥有范围、类型、计划单调时点、epoch、注册/触发引用 |
| ConfigEvent | config 类型/scope、前后版本、内容哈希/引用、生效屏障、ControlCommand |
| ControlCommand | command identity、SystemOwner/OwnerSession、类型、准确 target、内容哈希、状态前置条件、签发/到期时间、软件签名 |
| VersionActivationEvent | 旧新 Release/Strategy/参数、SchemaRegistryId、StateSchemaVersion、StrategyStateTransition、CutoverBarrier、CanonicalStateDigest、热备确认位置 |
| PrimaryLeaseChanged | lease identity、动作、范围、holder MachineIdentity、生效/到期单调时间、epoch、FencingToken、外部租约权威 |
| FencingTokenAdvanced | FailoverGroup/account、旧新 token、外部权威、原因、ControlCommand/FailoverCause |

只有通过身份、签名、期限、目标和版本前置条件验证的 ControlCommand 才进入分片日志。重复 command identity 返回原结果而不重复执行。配置和 timer 的实际生效顺序由 ShardSequence 决定。FencingToken 只能严格前进。

### 14. OperationalEvent v1

状态变化事件共享 `scope + previous_state + new_state + stable_reason + primary_cause_ref + effective_shard_seq`。

| 类型 | 附加必需 payload |
|---|---|
| MarketDataHealthChanged | venue/instrument、来源会话、最后有效/观察 SourceSequence、Gap 区间、恢复 snapshot |
| AdapterHealthChanged | venue、public/private/REST 通道、连接会话、故障分类、受影响能力 |
| OverloadStateChanged | 队列/模块、容量策略版本、等级、FailClose/Resync/Coalesce 动作 |
| OperationalModeChanged | StrategyInstance/DecisionDomain/FailoverGroup 与五阶段模式 |
| SafetyGateChanged | gate 类型、SelfRecovering/Latched、Open/Closed、关闭或重新验证证据 |
| TradingAuthorizationChanged | 授予/撤销、SystemOwner command 或允许继承的恢复证据、范围 |
| ReconciliationBreakChanged | break identity、类型、expected/observed 证据、Open/Resolved、解决事实 |
| LifecycleOperationChanged | operation identity、类型、target、阶段、成功/失败及稳定原因 |
| FailoverStateChanged | FailoverGroup、FailoverCause、旧新 MachineIdentity、FencingToken、阶段、FailoverAdmission |
| StateSnapshotPublished | snapshot identity、Release、StateSchemaVersion、SchemaRegistryId、StreamIdentity/ShardSequence、配置版本、长度/哈希、CanonicalStateDigest、引用 |

previous_state 必须与当前投影一致。无状态变化的周期检查只更新指标。Resolved 必须引用解释原问题的事实。OverloadStateChanged 不得授权合并任何权威市场、订单、风险或账务事件。StateSnapshotPublished 只能在快照完整写入并校验后形成。

### 15. 双表示与 Strategy Host

- 内存侧使用 Zig 原生对齐的具体 struct 和边界专用 tagged union，例如 ShardInputEvent、ShardOutputEvent、StrategyHostEvent；不创建全系统巨型 union。
- 日志/IPC 中每个 `EventType + SchemaVersion` 对应不可变 StableEventSchema，由手写编解码器逐字段处理。
- 禁止直接落盘 struct、指针、padding、切片头或 Zig enum 表示。
- 每个 schema 具有精确字段和长度规则；增加字段也发布新版本。首版不引入 TLV、反射、Protobuf、FlatBuffers 或代码生成框架。
- Python IPC 复用相同 event type、schema 和 payload，但用批次 framing，不逐条复制磁盘 magic/CRC。
- 输入批次头包含协议版本、SchemaRegistryId、DecisionDomain、HostSessionIdentity、HostBatchSequence、首末 ShardSequence、事件数、总字节数和批次校验。
- Host 握手校验协议、注册表、策略/参数、checkpoint schema 和订阅集合，不运行时协商 schema。
- Host 输出 IntentGroup/OrderIntent 必须带 session、batch、cursor、strategy、配置版本和确定性身份；TradingShard 把共享内存视为不可信边界并重新验证。
- 未知 schema、CRC 错误、序号缺口、旧 session 输出或落后越界进入 NeedsSnapshot/Recovering，不能跳过单条事件。
- 回测、仿真和实盘使用同一 Host 协议；生产资格回测不得绕过 IPC 直接调用 Python。

### 16. SchemaRegistry 与演进

- EventType 编号、规范名称和 EventFamily 永久稳定。
- SchemaVersion 在单个 EventType 内从 1 单调递增；已发布版本永不修改、重排或重新解释。
- 注册表记录类型、家族、版本、最大 payload、是否影响权威状态、允许边界和编解码器。
- 增删/重排字段，改变宽度、符号、比例尺、单位、缺失语义或枚举集合都发布新 SchemaVersion。
- 只是同一事实的表示变化使用新 schema；事实含义、所有者或因果身份改变则使用新 EventType。
- SchemaRegistryId 由注册表规范内容确定。日志段、Strategy Host 会话和 ReleaseArtifact 使用准确身份，不引用浮动最新版。
- 旧 decoder 和验证规则不能通过修改而改变历史解释。内存结构可以优化，但显式编码必须保持旧 schema。
- ReleaseArtifact 分别声明 ReadableSchemaSet 和 WritableSchemaSet；写端只产生明确集合，不能按消费者改变格式。

### 17. 未知类型、旧日志与跨版本发布

- StructuralScan 只验证边界、长度、序号和 CRC，可以凭 record_len 越过未知记录并报告。
- SemanticReplay、TradingShard 恢复、账本重建和热备遇到任何未知 EventType、SchemaVersion 或 flags 都失败关闭。
- 不能相信生产者设置的 `skippable` 位；首版不建立可忽略权威事件机制。
- 研究转换遇到未知事件只能保留或把分区标记 Degraded，不能默认无影响。
- Host 会话 SchemaRegistryId 不兼容则拒绝启动；运行中出现未知记录则终止数据流并从已确认 cursor 恢复。

发布使用两阶段兼容：

1. 新构建先部署读取能力，主节点仍写当前 schema。
2. 主、热备和 ForwardRollback 候选均证明能读目标 schema，热备追到同一屏障后，才由 ConfigEvent 在 CutoverBarrier 激活新写版本并轮换日志段。

同一 EventType 同时只有一个活动写版本，不双写、不按消费者变体编码。新 schema 激活后不能直接启动不支持它的旧二进制；ForwardRollback 是把旧业务逻辑重新构建为能读取当前日志/状态的新候选，而不是恢复历史二进制。

当前生产 ReadableSchemaSet 只必须覆盖 RecoverySchemaHorizon：最新合格快照及其后仍用于恢复的全部日志。删除旧 reader 前必须生成并验证新快照及尾部恢复。更早日志保持不可变，由版本化离线 decoder/ReleaseArtifact 解释；只要保留对象仍引用旧 schema，相应离线 decoder 就必须保留。

历史转换形成带血缘的新 ResearchDataset，不能替换 SourceArchive。RawIngressRecord 重新解析可以形成新派生数据，但不能改写当时驱动交易的分片决策日志。

### 18. 状态 schema

SchemaVersion、StateSchemaVersion 和 SchemaRegistryId 相互独立。

- StateSnapshotPublished/StrategyCheckpointPublished 只保存引用和元数据，状态内容使用独立格式。
- 权威快照头记录 StateSchemaVersion、ReleaseArtifact、SchemaRegistryId、StreamIdentity、ShardSequence、活动配置/规则版本、长度/校验和 CanonicalStateDigest。
- 快照后日志必须从 `snapshot_shard_seq + 1` 无缺口衔接。
- 未知 StateSchemaVersion 不猜测读取；可回退到更早已知快照并重放更多日志。
- AuthoritativeTradingState 不执行改变经济语义的 StateMigration。旧物理布局只能由显式 decoder 映射到相同规范状态，否则重建。
- 只有 StrategyPrivateState 可按 Keep/Migrate/Rebuild 显式迁移；RebuildableState 重建，EphemeralRuntimeState 永不持久化。
- 新状态 schema 写入前，主、热备和 ForwardRollback 候选必须具备读取能力。

### 19. 日志路由与恢复副作用

- RawIngressStream 只保存原始帧、CaptureSequence、连接/频道身份、接收/单调时间、长度、协议元数据和校验。
- 每个 TradingShard 决策日志保存该 DecisionDomain 实际观察或产生的全部权威 CanonicalEvent：路由输入、策略输出、风险结果、执行命令/结果、账务事实、控制和运行状态变化。
- 同一外部事实进入多个分片时具有不同 EventIdentity/ShardSequence，但保持相同 SourceFactIdentity。
- 输入先获得 ShardSequence；同步派生输出按稳定模块顺序逐条获得后续序号。异步结果返回时排到当时日志尾部，不能倒插。
- 恢复按原序重建 AuthoritativeTradingState。策略重放输入恢复私有状态，但重新计算的输出只用于 VerificationReplay 比较，不能再次进入风险或发送路径。
- 历史 OrderCommand 只用于重建 Order、reservation 和审计链，恢复时零发送。恢复完成后通过 Venue 对账解决 Live、终态及 Unknown，只有新命令可进入网关。
- 不建立第三套热路径全局事件日志；研究面异步封存 RawIngressStream 和分片决策日志。
- LogCommitWatermark 是日志线程已完整写入的最高 StreamSequence 运行时进度，不作为同一流的自引用事件。
- 普通订单热路径不等待同步 fsync。VersionActivation、schema 切换等低频持久屏障可以等待日志 flush/必要 fsync 和热备确认。

### 20. RunMode、FactOrigin 与秘密隔离

每个 StreamIdentity 解析到不可变 LogStreamManifest，记录 RunMode、范围、初始 ReleaseArtifact、SchemaRegistryId、MachineIdentity、创建时间、Venue 环境及各日志段身份、序号范围、大小和内容哈希。

RunMode 只允许 ProductionLive、Testnet、L2ReplayBacktest、ShadowSimulation、ResearchBacktest、RecoveryVerification；同一 StreamIdentity 不能切换 RunMode。

ShadowSimulation 可以同时保存真实与模拟回报，但 SourceFactIdentity 空间和 FactOrigin 必须分离。SimulatedVenue 事实永远不能进入 ProductionLive 的真实 ExchangeAccount 账本。Production 启动/恢复校验 RunMode 与 SecurityAdmission，拒绝 Testnet/回测/仿真流作为可交易恢复源。

SecretMaterial、Authorization、签名值、cookie、完整私有请求头及解密凭证不得进入 CanonicalEvent、LogStreamManifest、错误文本或请求内容哈希。

### 21. 验收矩阵

新 schema 进入生产 WritableSchemaSet 前必须具备：

1. 注册表 lint：46 个 EventType 唯一、家族正确，旧编号/schema 未修改或复用。
2. 每个 v1 schema 的最小、最大和可选字段组合 golden bytes。
3. 相同逻辑事件重复编码逐字节相同；Zig encode/decode/re-encode 字节不变。
4. Python 订阅及输出类型与 Zig 共用 golden corpus。
5. 长度、计数、枚举、整数边界、溢出和 1 MiB 上限拒绝样例。
6. header/payload/footer 损坏及每个尾部截断位置的恢复测试。
7. StructuralScan 越过未知记录，而 SemanticReplay、TradingShard 和 Host 拒绝未知类型、版本及 flags。
8. 当前主、候选、热备和 ForwardRollback 的 Readable/WritableSchemaSet 兼容矩阵。
9. 旧快照加日志、新快照加日志得到相同 CanonicalStateDigest。
10. VerificationReplay 得到相同 Intent、RiskDecision、OrderCommand、LedgerTransaction 和最终状态，且历史命令零发送。
11. 重复、乱序 Venue 事实不会重复改变订单、仓位或账本。
12. ProductionLive 拒绝 Testnet/SimulatedVenue 事实进入真实账本。
13. decoder fuzz 不发生越界、无限循环或无界分配。
14. 64 字节新版编码器在目标 Debian 13/Zig 0.17 候选环境重新验证至少 2M events/s 持续吞吐及 10 秒 5M events/s 突发。
15. 性能测试开启 CRC、真实内存拷贝和领域验证，不能只测空 payload。

现有 56 字节事件头原型只证明旧布局的初步容量，不替代 64 字节 v1 格式和完整 payload 的上述生产验收。

## Comments

- 2026-07-29：经事件分类、字段、日志格式、身份、重放、版本演进和兼容性逐项访谈及整票确认后解决。
