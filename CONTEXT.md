# Quantitative Trading

面向中心化加密交易所现货与永续合约的多策略交易领域。本文只定义系统中的规范领域语言及其不变量。

## Strategy Ownership

**StrategyDefinition**:
不可变且带版本的交易算法及其参数结构，可以产生多个运行实例。
_Avoid_: Strategy code, strategy template

**StrategyInstance**:
某个 StrategyDefinition 的一次运行实例；同一 VirtualPortfolio 同一时刻至多有一个 StrategyInstance 获得交易授权。
_Avoid_: Strategy process, strategy thread

**StrategyInstanceIdentity**:
控制面分配给一个逻辑 StrategyInstance 的稳定 128 位身份；Host 重启、参数版本或 checkpoint 更新不得改变它，创建 StrategySuccessor 才进入新的身份空间。
_Avoid_: HostSessionIdentity, process id, strategy name

**StrategyHost**:
承载同一 DecisionDomain 内一组 Python 中低频 StrategyInstance 的隔离运行归属；其故障不得阻塞交易核心或其他 StrategyHost。
_Avoid_: Python worker, strategy thread

**StrategyHostAtomicBridge**:
由 Zig 实现并以最小 C ABI 暴露给 Python 的 IPC 桥；它独占共享内存游标的 acquire/release 原子操作，在共享槽位与 Python 自有 `bytes` 之间执行每方向一次有界复制，并以一次 producer cursor 发布原子提交单回调的有界多 frame 输出。Python 不得直接获得共享内存指针或原子游标。
_Avoid_: Python atomic cursor, zero-copy strategy view, shared-memory pointer API

**HostSupervisor**:
位于活动 Zig TradingEngine 内、由对应 TradingShard 拥有的 StrategyHost 生命周期管理器；它创建会话与共享内存，启动、监测、失效、终止并重建唯一对应的 Python Host，但不授予 Python 任何权威交易状态所有权。
_Avoid_: OS service manager, Python parent process, strategy supervisor

**StrategyHostControlChannel**:
HostSupervisor 创建并继承给唯一 StrategyHost 的两条匿名单向 pipe；它只传送有界、版本化的生命周期/恢复控制帧和 checkpoint bytes，不承载市场事件、OrderIntent 或任何权威交易命令。
_Avoid_: Command bus, intent ring, arbitrary RPC

**StrategyStateDigest**:
在明确 StrategyCursor 上对一个 StrategyInstance 的状态 schema、配置版本、next IntentSequence 与规范 PortableStrategyState 计算的稳定摘要；它验证策略私有状态重放收敛，不等同于核心 AuthoritativeTradingState 的 CanonicalStateDigest。
_Avoid_: CanonicalStateDigest, checkpoint file CRC, Python hash()

**HostSessionIdentity**:
由 EngineFencingToken、TradingShardId 与单调 HostGeneration 组成的一次 StrategyHost 会话身份；Host 重启即变化，TradingShard 必须拒绝旧会话迟到的意图、确认和 checkpoint 发布。
_Avoid_: Process id, StrategyHost identity, HostBatchSequence

**HostBatchSequence**:
在一个 HostSessionIdentity 内从 1 严格连续递增的 `u64` IPC 批次序号；仅用于检测批次重复、乱序和缺口，会话变化后重新开始，不表示权威交易进度。
_Avoid_: ShardSequence, StrategyCursor, durable log offset

**StrategyInputBatch**:
TradingShard 发送给 StrategyHost 的有界 IPC 传输容器；它声明连续覆盖的 first/last ShardSequence，并携带该 Host 订阅所需的有序事件记录，但其分批边界不对 StrategyInstance 可见且不具有决策语义。
_Avoid_: Strategy callback, decision interval, durable batch identity

**StrategyOutputFrame**:
StrategyHost 返回 TradingShard 的有界 IPC 容器；每个 frame 原子承载一条独立 OrderIntent 或一个完整 IntentGroup，携带当前会话、来源 batch、策略 cursor 与配置证据，但不得包含 Python 生成的风险、命令、客户端订单号或网关权威字段。
_Avoid_: OrderCommand, transport batch, partial IntentGroup

**HostActivationBarrier**:
StrategyHost 完成精确兼容检查，并使获准 StrategyInstance 从指定 checkpoint 无权重放后，由 TradingShard 记录 `HostActivated` 事实形成的授权边界；Host 必须实际应用该事实的 ShardSequence 后才可使用其中的 StrategyActivationIdentity，屏障之前的 Python 输出一律不得进入风控。
_Avoid_: Process started, Host ready flag, first intent

**StrategyActivationIdentity**:
某个 StrategyInstance 一次 HostActivated 权威事实的 128 位身份；每次撤权后立即失效，即使 HostSessionIdentity 未变化，重新激活也必须获得新身份并由所有输出 frame 携带。
_Avoid_: HostSessionIdentity, StrategyInstanceIdentity, boolean active flag

**StrategyCursor**:
某个 StrategyInstance 已按确定顺序完整应用的最后一个 `u64` ShardSequence；恢复交易权限前必须追赶到核心指定的当前屏障，不得以 HostBatchSequence 替代。
_Avoid_: Queue offset, latest event

**StrategyCheckpoint**:
在明确 StrategyCursor 上保存的一组版本化策略私有状态；其身份绑定 StrategyDefinition、参数及状态 schema，恢复后必须通过事件重放追赶。
_Avoid_: Market snapshot, process dump

**PortableStrategyStateJsonV1**:
PortableStrategyState 的首版规范编码；它是由显式状态 schema 约束、字段顺序固定且无空白的 JSON 子集，只允许基础值和有界结构，禁止浮点、任意映射、未声明字段及解释器对象。
_Avoid_: General JSON, pickle, Python object graph

**StrategyCheckpointPublished**:
在明确 StrategyCursor 上发布 StrategyCheckpoint 身份、内容哈希、版本与存储引用的不可变事实；事件本身不嵌入 checkpoint 内容。
_Avoid_: StrategyCheckpoint payload, process snapshot, unverified file path

**VirtualPortfolio**:
独立于进程和策略版本而持续存在的策略经济归属，承载仓位、现金、费用及风险额度；默认只对应一条策略演进链，但可以使用多个 ExchangeAccount。
_Avoid_: Strategy account, subaccount

**TreasuryPortfolio**:
不运行交易策略的系统资金归属，承载尚未分配给策略的自有资金及确定性分配尾差。
_Avoid_: SuspenseAccount, house strategy

**DecisionDomain**:
必须在同一确定顺序下完成决策的一组策略经济状态；每个 VirtualPortfolio 同一时刻只属于一个 DecisionDomain。
_Avoid_: TradingShard, strategy group

## Account Ownership

**ExchangeAccount**:
交易所识别的真实账户及其资金、保证金、订单和净仓位；可以承载多个 VirtualPortfolio，但每个订单的投资组合归属必须唯一。
_Avoid_: Account, real account, broker account

**PortfolioPosition**:
某个 VirtualPortfolio 对某个品种持有的经济敞口，由归属于该投资组合的成交及账本记录推导；现货持仓是资产余额的成本与 PnL 投影，不构成可重复计价的第二份资产。
_Avoid_: Position, strategy position

**ExchangePosition**:
交易所报告的某个 ExchangeAccount 的实际仓位，保留交易所的单向或双向持仓语义。
_Avoid_: Position, real position

**PortfolioBalance**:
VirtualPortfolio 在某个 Asset 上的账本余额，由 LedgerTransaction 推导。
_Avoid_: Balance, strategy balance

**ExchangeBalance**:
ExchangeAccount 上由交易所报告的资产余额，保留交易所的总额、可用及占用语义。
_Avoid_: Balance, real balance

**PortfolioMarginReservation**:
某个 VirtualPortfolio 为永续持仓、未完成增仓订单和费用缓冲占用的自身结算资产；它是资金约束而不是新的余额、支出或资产转移。
_Avoid_: PortfolioBalance, TradingFee, ExchangeMarginBucket

**ExchangeMarginBucket**:
Venue 对某个 ExchangeAccount 与逐仓 Instrument 报告的真实保证金范围；它反映净 ExchangePosition，不能宣称由其中一个 VirtualPortfolio 独占拥有。
_Avoid_: PortfolioMarginReservation, strategy collateral

**MarginRules**:
某个 Venue、Instrument 和账户模式下决定保证金档位、费率、合约乘数、费用与舍入的版本化规则；历史计算必须绑定当时版本。
_Avoid_: StrategyLimit, leverage setting

**MarginModel**:
保证金计算与抵押品边界的版本化模型身份；首版唯一支持 IsolatedLinearUsdtV1，其他模型不得用兼容字段静默混入。
_Avoid_: Account mode string, MarginRules version

**VenueInitialMargin**:
按 MarginRules 对目标持仓及挂单计算的 Venue 最低初始保证金要求。
_Avoid_: InternalInitialMargin, ExchangeMarginBucket

**InternalInitialMargin**:
在 VenueInitialMargin 之上加入本系统安全缓冲后用于 OrderIntent 准入和 PortfolioMarginReservation 的内部要求；它不得低于 VenueInitialMargin。
_Avoid_: VenueInitialMargin, PortfolioBalance

**PortfolioMarginEquity**:
某个 VirtualPortfolio 在一个逐仓 Instrument 上的已占用保证金与按标记价格计算的 UnrealizedPnL 之和；已结算费用和损益通过 PortfolioBalance 影响它。
_Avoid_: NetAssetValue, ExchangeBalance

**InternalMaintenanceMargin**:
按 VirtualPortfolio 毛持仓和当前 MarginRules 计算、并加入内部保守要求的维持保证金；它不得低于对应 Venue 要求。
_Avoid_: InternalInitialMargin, Venue maintenance display

**PortfolioMarginBuffer**:
PortfolioMarginEquity 扣除 InternalMaintenanceMargin 及预计平仓或强平费用缓冲后的结算资产余额。
_Avoid_: Margin ratio, free PortfolioBalance

**ExchangeMarginBuffer**:
根据 Venue 报告的 ExchangeMarginBucket、净 ExchangePosition、标记价格和风险档位得到的真实逐仓安全余量。
_Avoid_: PortfolioMarginBuffer, account available balance

**PortfolioLiquidationThreshold**:
固定某个 VirtualPortfolio 的逐仓持仓、保证金占用和 MarginRules 后，标记价格沿不利方向首次使 PortfolioMarginBuffer 不大于零的内部风险价格。
_Avoid_: Venue liquidation price, guaranteed liquidation price

**ExchangeLiquidationThreshold**:
基于净 ExchangePosition 和 ExchangeMarginBucket 计算并与 Venue 报告值核对的真实账户强平风险价格。
_Avoid_: PortfolioLiquidationThreshold, bankruptcy price

**LiquidationDistance**:
当前标记价格到相应 liquidation threshold 的不利方向价格 tick 数及基点距离；零仓位不具有该值，输入不完整时必须为 Unknown。
_Avoid_: Margin ratio, guaranteed time to liquidation

**MarginSafetyGates**:
依次约束新增风险、触发预警和触发 KillSwitch 的 OpeningGate、WarningGate 与 KillGate；每档同时比较绝对结算资产、名义价值基点和 LiquidationDistance，并采用最严格结果。
_Avoid_: Margin state machine, Venue margin ratio

**MarginAdjustment**:
显式增加或释放某个 VirtualPortfolio 在一个 ExchangeMarginBucket 中保证金占用的不可变事实，记录资金所有者、金额、规则版本和调整前后安全余量。
_Avoid_: Automatic top-up, PortfolioTransfer, balance correction

**GrossPortfolioMargin**:
同一 ExchangeAccount 内全部 VirtualPortfolio 的 PortfolioMarginReservation 之和，不应用跨投资组合的方向抵消。
_Avoid_: VenueNetMargin, account used margin

**VenueNetMargin**:
Venue 根据净 ExchangePosition 和 ExchangeMarginBucket 实际要求或占用的保证金。
_Avoid_: GrossPortfolioMargin, PortfolioMarginReservation

**AccountNettingBenefit**:
GrossPortfolioMargin 高于 VenueNetMargin 的差额，表示策略当前互相抵消带来的暂时真实保证金节省；它不属于任何策略，也不能转化为购买力。
_Avoid_: Free balance, profit, StrategyLimit

**MarginReconciliationBreak**:
本地与 Venue 在账户模式、杠杆、逐仓仓位、保证金、风险档位或强平阈值上的未解决差异；除 MarginRules 明确的最小单位舍入外，它必须锁存新增风险权限。
_Avoid_: Display variance, configurable tolerance

**PortfolioReduceOnly**:
订单成交后不得增加其 VirtualPortfolio 的绝对 PortfolioPosition，也不得穿过零点建立反向仓位的组合级约束。
_Avoid_: VenueReduceOnly, close signal

**VenueReduceOnly**:
订单成交后不得增加净 ExchangePosition 绝对值的 Venue 级约束；它可能与 PortfolioReduceOnly 对同一订单得出不同结论。
_Avoid_: PortfolioReduceOnly, risk-reducing intent

## Order Decisions

**OrderIntent**:
StrategyInstance 对一个交易所订单动作提出的不可变请求，归属于唯一的 VirtualPortfolio 和 ExchangeAccount；其 OrderIntentIdentity 由 StrategyInstanceIdentity 与持久化 IntentSequence 确定性组成，重放不得产生新身份。它不保证通过风控或被发送。
_Avoid_: Order, signal, order request

**OrderIntentIdentity**:
由 StrategyInstanceIdentity 与该实例 PortableStrategyState 中从 1 严格递增的 `u64` IntentSequence 组成的业务幂等身份；无权恢复仍按确定路径推进序号但禁止发布，HostSessionIdentity 与 HostBatchSequence 仅作为独立授权包络，不进入此身份。
_Avoid_: ClientOrderId, HostSessionIdentity, random request id

**StrategyIntentRejected**:
StrategyOutputFrame 已具有可验证业务身份但因 stale 或其他 Host seam 准入原因未进入风控时记录的幂等事实；它消费同一 OrderIntentIdentity，但不得创建 RiskDecision、RiskReservation、OrderCommand 或 Order。
_Avoid_: RiskDecision, malformed-frame metric, OrderRejected

**IntentGroup**:
同一次策略决策产生、具有稳定成员顺序的一组 OrderIntent，共享风险准入及部分执行处置政策；其 IntentGroupIdentity 由 StrategyInstanceIdentity 与首个连续成员 IntentSequence 派生，成员顺序不构成执行依赖，也不承诺交易所原子成交。
_Avoid_: Basket order, atomic order

**IntentGroupIdentity**:
由 StrategyInstanceIdentity 与该组第一个成员的 `u64` IntentSequence 组成的确定性身份；组内成员必须按稳定顺序占用连续 IntentSequence，因而不需要独立 GroupSequence。
_Avoid_: Batch id, GroupSequence, Venue basket id

**PartialExecutionPolicy**:
IntentGroup 对成员部分成功的显式处置政策；首版仅有 Independent 与 CancelRemaining，均不能回滚 Fill 或声称 Venue 原子性。
_Avoid_: Batch atomicity, fill rollback, compensation transaction

**OrderNormalizationPolicy**:
OrderIntent 对不符合 InstrumentRules 的价格与数量选择 RequireExact 或 AllowConservativeNormalization 的政策；规范化结果必须在风控前确定并且不得增加侵略性或风险敞口。
_Avoid_: Adapter rounding, best-effort order, implicit legalization

**CapabilityDegradationPolicy**:
OrderIntent 或 IntentGroup 对目标 Venue/产品不具备所请求订单能力时，显式允许哪些非等价替代路径的政策；缺失授权即拒绝，适配器不得自行推断。
_Avoid_: Adapter fallback, best effort, automatic downgrade

**NonDegradableCapability**:
缺失时必须拒绝 OrderIntent、且不能被 CapabilityDegradationPolicy 弱化的 Venue 执行安全能力，包括原生 Post-only、VenueReduceOnly、价格保护及目标账户/持仓模式约束。
_Avoid_: Preferred capability, local emulation, best-effort safety

**CapabilityProfile**:
在明确 Venue、产品、环境及账户适用范围内，经官方资料和准入证据验证并版本化生效的订单身份、变更、批量、限流与对账能力声明。
_Avoid_: Adapter flags, current documentation assumption, global Venue capability

**VenueOrderCapabilities**:
CapabilityProfile 向策略暴露的只读、规范化、版本化订单能力投影；它帮助策略选择语义，但不替代 OrderIntent 的明确要求或发送时资格复核。
_Avoid_: Adapter endpoint flags, raw Venue features, execution guarantee

**TransportBatch**:
为减少传输开销而按稳定顺序装入一次 Venue 请求的一组独立 OrderCommand；它不提供领域原子性，每项结果、风险占用和 Unknown 恢复仍独立。
_Avoid_: Atomic batch, basket order, batch transaction

**CancelConfirmCreate**:
非原地改单的规范降级路径；先确认旧 Order 已不再存活，再基于最新事实重新风控并创建具有新身份及 predecessor 关系的替代 Order，任何 PendingCancel 或 Unknown 都阻止新单发送。
_Avoid_: Cancel-replace, amend emulation, overlapping replace

**TargetRemainingQuantity**:
Amend 在所引用 OrderRevision 和累计成交屏障上希望继续保留的未成交数量；适配器负责转换为 Venue 所需的总量或剩余量字段。
_Avoid_: New original quantity, adapter-specific amend quantity

**DispatchDeadline**:
OrderCommand 允许首次发送的最晚单调时点；它不决定已提交或 Live Order 的 Venue 存活期限。
_Avoid_: TimeInForce, GTD expiry, order cancellation timer

**CanonicalRejectReason**:
跨 Venue 稳定的订单拒绝原因；策略只能依赖该分类，原始错误码和响应作为证据保留但不构成策略接口。
_Avoid_: Raw Venue error code, retry category, error text matching

**OrderCommand**:
OrderIntent 通过风险准入后形成的不可变报单、撤单或改单指令。
_Avoid_: Order request, execution request

**Order**:
一个交易所侧订单身份的生命周期记录，拥有稳定的客户端订单标识，并永久保留其 VirtualPortfolio 与 ExchangeAccount 归属。
_Avoid_: OrderIntent, OrderCommand

**ExecutionReport**:
交易所产生的不可变订单事实，可能重复、延迟或乱序到达。
_Avoid_: Order update, OrderState

**OrderState**:
由 OrderCommand 和已接受的 ExecutionReport 按订单状态规则计算出的当前投影。
_Avoid_: ExecutionReport, order truth

## Events

**CanonicalEvent**:
跨交易核心、适配器、策略 Host、日志与重放使用的规范不可变消息；它可以表达外部事实、内部决定或命令，但不能表达对既有事实的原地覆盖。
_Avoid_: RawIngressRecord, telemetry, mutable state update

**EventFamily**:
CanonicalEvent 按唯一领域所有者所属的分类，只允许 MarketEvent、VenueAccountEvent、StrategyEvent、RiskEvent、ExecutionEvent、AccountingEvent、ControlEvent 或 OperationalEvent；它是注册表分类，不是运行时继承层次。
_Avoid_: Class hierarchy, transport topic, log stream

**EventEnvelope**:
CanonicalEvent 的稳定公共元数据，标识事件类型、结构版本、流内序号及来源、接收、单调和审计时间，并保护记录边界与完整性；领域身份与可选因果关系仍属于具体事件。
_Avoid_: Event payload, in-memory base class, domain aggregate

**StreamIdentity**:
一个稳定日志流跨分段、重连、重启及主备切换保持不变的身份；只有创建语义上不同的新流时才分配新身份。
_Avoid_: File name, process id, connection id

**StreamSequence**:
StreamIdentity 内每条稳定记录严格连续递增且永不重置的序号；在 TradingShard 决策日志中称为 ShardSequence。
_Avoid_: SourceSequence, global sequence, per-segment offset

**VenueSourceStreamIdentity**:
标识一个 AdapterSession 内可独立判断连续性的 Venue REST 或 WebSocket 来源流；来源序列重置或失去连续性时必须形成新身份。
_Avoid_: StreamIdentity, channel name, connection object

**VenueSourceSequence**:
VenueSourceStreamIdentity 内由 Venue 提供或由适配器按接收顺序分配的序号；它只证明该来源可观察范围内的顺序，不得跨来源比较或伪装成全局顺序。
_Avoid_: StreamSequence, global sequence, exchange-time order

**BootstrapSnapshotIdentity**:
一次完整 Venue 账户或行情快照屏障的身份；后续单项观察只有明确引用该身份且来源连续时才能推进相应投影。
_Avoid_: Snapshot file, latest state, reconnect generation

**MonotonicEpochIdentity**:
标识一段可安全比较和相减的本机单调时钟域；进程重启或时钟域变化产生新身份，跨 epoch 不得计算持续时间。
_Avoid_: StreamIdentity, boot time, UTC clock

**EventIdentity**:
由不可变 StreamIdentity 与该流内唯一 StreamSequence 确定性组成的事件身份；重放必须恢复相同身份，热路径不为它生成随机 UUID。
_Avoid_: correlation_id, source sequence, process-local counter

**SourceFactIdentity**:
外部或经济事实本身的幂等身份；同一事实重复到达可以产生不同 EventIdentity，但必须保持相同 SourceFactIdentity 并且只能改变权威状态一次。
_Avoid_: EventIdentity, arrival sequence, payload hash without identity rules

**CorrelationIdentity**:
从 IntentGroup 或 OrderIntent 的确定性身份派生、用于关联一次交易决策链的身份；它不表示日志顺序或直接因果关系。
_Avoid_: EventIdentity, causation reference, random trace UUID

**InMemoryEvent**:
CanonicalEvent 在一个明确进程边界内使用的原生对齐结构及边界专用 tagged union；它只承载该边界允许的事件，不能直接持久化或作为跨进程 ABI。
_Avoid_: StableEventSchema, global event union, serialized struct image

**StableEventSchema**:
一个 EventType 与 SchemaVersion 对应的不可变字段、整数宽度、单位、枚举和长度契约，用于日志与策略 Host IPC；任何字段语义变化都必须形成新版本并由显式编解码器处理。
_Avoid_: InMemoryEvent layout, best-effort decoder, self-describing object

**ProvisionalEventSchema**:
尚未进入任何受支持 RecoverySchemaHorizon 的开发期事件契约，可以与其快照、夹具和摘要原子替换；一旦进入受支持恢复基线即成为 StableEventSchema。
_Avoid_: StableEventSchema, backward-compatible release, production schema

**EventType**:
CanonicalEvent 的永久稳定类型身份，具有唯一且永不复用的整数编号、规范名称和唯一 EventFamily；领域事实的含义或所有者改变时必须形成新的 EventType。
_Avoid_: SchemaVersion, in-memory union tag, reused enum value

**SchemaRegistryId**:
由全部已发布 EventType 与 StableEventSchema 规范内容确定的注册表身份；日志段、策略 Host 会话和 ReleaseArtifact 用它声明准确兼容集合，不能引用浮动的最新版。
_Avoid_: Release version, database service, latest schema

**StructuralScan**:
不解释事件业务语义，只验证稳定日志的记录边界、长度、序号和校验和并定位下一条记录的扫描；它可以越过未知记录，但不能据此恢复权威状态。
_Avoid_: SemanticReplay, event decoding, recovery qualification

**SemanticReplay**:
使用明确支持的 StableEventSchema 解码并应用全部 CanonicalEvent，以重建确定性权威状态的重放；遇到任何未知 EventType 或 SchemaVersion 必须失败关闭。
_Avoid_: StructuralScan, best-effort replay, research filtering

**VerificationReplay**:
SemanticReplay 中重新运行策略、风控或账务计算并把结果与已记录 CanonicalEvent 比较的模式；重新计算的历史输出不得再次触发风险占用、账务或 Venue 副作用。
_Avoid_: Live execution, command resend, output regeneration

**ReadableSchemaSet**:
一个 ReleaseArtifact 能够完整解码并进行 SemanticReplay 的 EventType 与 SchemaVersion 集合；候选、热备和 ForwardRollback 版本必须覆盖其可能接管的全部恢复范围。
_Avoid_: SchemaRegistryId, best-effort compatibility, latest schema

**WritableSchemaSet**:
一个 ReleaseArtifact 可以产生的 StableEventSchema 集合；每个 EventType 同一时刻只能有一个活动写版本，并且只能在事件屏障上切换。
_Avoid_: ReadableSchemaSet, dual write, per-consumer encoding

**RecoverySchemaHorizon**:
当前生产 ReleaseArtifact 必须能够完成 SemanticReplay 的最早恢复边界，由最新合格快照及其后仍参与恢复的全部事件决定；更早历史 schema 可由版本化离线重放工具承担。
_Avoid_: RetentionPolicy, system genesis, archive deletion boundary

**LogCommitWatermark**:
日志线程已经完整写入并通过结构校验的最高 StreamSequence 运行时进度；它用于持久屏障和复制判断，但不能作为同一日志流中的普通事件自我记录。
_Avoid_: StreamSequence, fsync guarantee, CanonicalEvent

**LogStreamManifest**:
描述一个 StreamIdentity 的 RunMode、范围、初始构建、SchemaRegistryId、生产者身份及日志段序号和内容哈希的不可变清单。
_Avoid_: Directory listing, mutable latest pointer, log segment header

**RunMode**:
一个日志流不可变的运行用途，只允许 ProductionLive、Testnet、L2ReplayBacktest、ShadowSimulation、ResearchBacktest 或 RecoveryVerification；环境切换必须创建新 StreamIdentity。
_Avoid_: Config flag, FactOrigin, OperationalMode

**FactOrigin**:
VenueAccountEvent 对 RealVenue 或 SimulatedVenue 的不可变来源分类；真实来源还区分 Production 与 Testnet，模拟来源必须绑定 SimulationRunIdentity。
_Avoid_: RunMode, event producer process, market data source

**RawIngressRecord**:
交易所 WebSocket、REST 或其他外部连接收到的原始帧及其接入元数据；它供重新解析与审计使用，不等同于已验证和标准化的 CanonicalEvent。
_Avoid_: MarketEvent, ExecutionReport, normalized event

**TimerEvent**:
由实盘单调时钟或回测虚拟时钟在稳定 timer 身份与计划时点上产生的 CanonicalEvent；策略只能通过它观察时间驱动。
_Avoid_: Direct clock read, callback timer, wall-clock polling

**ConfigEvent**:
在明确分片屏障激活一个版本化配置内容哈希的 CanonicalEvent；它使实盘、热备和重放使用相同配置生效顺序。
_Avoid_: Mutable config file, environment variable update, latest config

**MarketDataHealthChanged**:
记录某个 Venue 与 Instrument 的权威行情健康状态变化及来源序号证据的 OperationalEvent。
_Avoid_: MarketEvent, periodic health metric, inferred availability

**ReconciliationBreakChanged**:
打开或解决一个具有稳定身份和明确范围的 ReconciliationBreak 的 OperationalEvent；解决事件必须引用原差异，不能删除其历史。
_Avoid_: Warning log, balance overwrite, mutable issue row

**StateSnapshotPublished**:
在明确分片屏障发布权威状态快照身份、内容哈希、StateSchemaVersion 与存储引用的 OperationalEvent；事件本身不嵌入快照内容。
_Avoid_: Snapshot payload, process image, unverified file path

## Accounting

**LedgerTransaction**:
由一个唯一经济事实确定性产生的不可变账本事务；同一源事实与账务类型只能生成一次，事务必须保留到源事实的审计引用，已记录事务只能通过引用原事务的新冲正及更正事务修正。
_Avoid_: LedgerEntry, journal row

**LedgerPosting**:
LedgerTransaction 内对某个资产、仓位或权益账户的一条变化记录；同一事务的全部记录原子生效，并在各自计量单位内满足守恒规则。
_Avoid_: LedgerEntry, balance update

**ReconciliationBreak**:
Venue 事实与系统可解释状态之间尚未解决的差异；它必须保持显式，不能通过猜测订单或投资组合归属来消除。
_Avoid_: Reconciliation warning, rounding error

**SuspenseAccount**:
暂存已确认但尚不能可靠归属到 VirtualPortfolio 或 TreasuryPortfolio 的账本金额；每项余额必须关联一个 ReconciliationBreak。
_Avoid_: TreasuryPortfolio, rounding account

**ReportingAsset**:
用于汇总展示资产价值与 PnL 的指定 Asset；它不改变权威账本中的原始计量单位。
_Avoid_: Base currency, settlement currency

**ValuationSnapshot**:
在明确时刻按照 ValuationRoute，将原币余额与仓位换算为 ReportingAsset 的估值事实集合；缺失、不健康或过期的价格必须保留为未估值状态。
_Avoid_: Balance, mark-to-market entry

**ValuationRoute**:
某个 Asset 到 ReportingAsset 的版本化固定换算路径及价格来源；稳定币不因此被假定为等值，运行时也不自动改选路径。
_Avoid_: Best conversion path, implicit FX rate

**NetAssetValue**:
某个 VirtualPortfolio 在 ValuationSnapshot 下以 ReportingAsset 表示的净值；现货资产余额只估值一次，衍生品敞口按其产品公式加入未结算价值。
_Avoid_: Gross exposure, duplicated position value

**CapitalFlow**:
改变被评估主体所获资本但不构成交易损益的资产流入或流出；对 VirtualPortfolio 表现为 PortfolioTransfer，对 ExchangeAccount 表现为 ExternalTransfer。
_Avoid_: Profit, loss, trading income

**AverageCost**:
某个 VirtualPortfolio 在某个 Instrument 上持仓的权威移动加权平均成本，由 PositionQuantity 与 OpenCost 确定；同向增仓增加总成本，减仓按比例释放成本，反向成交先平旧仓再为剩余成交量建立新成本。手续费与资金费用不计入该成本。
_Avoid_: CostBasis, entry price, FIFO cost

**OpenCost**:
某个 PortfolioPosition 尚未因平仓而释放的原生报价或结算 Asset 总成本；部分平仓的除法余数保留其中，完全平仓时必须与持仓数量同时归零。
_Avoid_: Average entry price, market value, fee-inclusive cost

**TradingFee**:
Venue 因某个 Fill 实际扣收的费用，按扣收 Asset 独立归属于该 Fill 的 VirtualPortfolio；它不改变 AverageCost。
_Avoid_: Transaction cost, cost-basis adjustment

**TradingRebate**:
Venue 因某个 Fill 实际返还的收入，按返还 Asset 独立归属于该 Fill 的 VirtualPortfolio；它不作为负手续费修改原始 TradingFee。
_Avoid_: Negative fee, cost-basis adjustment

**FundingSettlement**:
Venue 在某个永续合约资金费结算时点对 ExchangeAccount 确认的实际应付或应收经济事实。
_Avoid_: Funding rate, estimated funding

**FundingAllocation**:
根据资金费结算时点各 VirtualPortfolio 的有效有符号持仓，将 FundingSettlement 确定性归属到各投资组合的应付或应收金额；分配尾差必须显式保留。
_Avoid_: Funding estimate, equal split

**RealizedPnL**:
由不可变成交或结算事实按照 AverageCost 确定性计算的权威派生结果；它对既有账本经济变化作损益分类，不产生重复的余额变化。
_Avoid_: Cash flow, additional ledger credit

**UnrealizedPnL**:
使用当前持仓、AverageCost 与可追溯市场价格计算的估值结果；它只属于 ValuationSnapshot，不进入权威账本。
_Avoid_: Accrued profit, mark-to-market posting

**ExternalTransfer**:
由真实资金进入、离开或跨越 ExchangeAccount 边界产生的资产划转，必须由相应的 Venue 或外部托管事实支撑。
_Avoid_: Portfolio allocation, balance correction

**PortfolioTransfer**:
同一 ExchangeAccount 内两个 VirtualPortfolio 之间对同一 Asset 进行的等额资金归属转移；它不改变 ExchangeBalance，也不产生 RealizedPnL。
_Avoid_: Withdrawal, deposit, asset conversion

**OpeningBalance**:
ExchangeAccount 首次启用时，由明确切换时点的已核对 Venue 快照建立的期初资产事实；首版要求该账户当时不存在仓位或未完成订单，资产默认归属 TreasuryPortfolio。
_Avoid_: Deposit, inferred history

**VenueAdjustment**:
Venue 确认但不具备 Fill 语义的余额或仓位变化事实，例如特定结算、分摊或人工调账；能够可靠归属时进入相应 VirtualPortfolio，否则进入 SuspenseAccount。
_Avoid_: Synthetic Fill, silent balance correction

**EffectiveTime**:
LedgerTransaction 所代表经济事实实际发生或应归属的时间，用于期间 PnL 归属。
_Avoid_: Arrival time, booking order

**RecordedTime**:
系统接受并追加 LedgerTransaction 的时间；迟到或更正事实保留其原 EffectiveTime，但不得倒插改变既有记录顺序。
_Avoid_: Venue event time, restated time

## Risk Authority

**StrategyLimit**:
某个 VirtualPortfolio 可使用的资金、敞口、单笔订单及速率限制；它可以版本化热更新，但不得超过所属 ExchangeAccount 的 AccountSafetyCeiling。
_Avoid_: Account cap, strategy parameter

**AccountSafetyCeiling**:
执行网关对整个 ExchangeAccount 强制执行的账户级风险上限；任何策略额度、风险租约或订单命令都不能突破。
_Avoid_: StrategyLimit, advisory warning

**RiskLease**:
全局或账户风控授予某个 DecisionDomain 的限时、带版本风险权限，限定可使用的账户、资金、敞口和订单速率。
_Avoid_: Risk limit, risk config

**RiskReservation**:
某个已接受 OrderIntent 对 RiskLease 可用额度的具体占用；增加风险的 OrderCommand 在发送前必须拥有该占用。
_Avoid_: Frozen balance, pending risk

**RiskDecision**:
本地风控对一个明确 OrderIntent 作出的不可变接受或拒绝事实，记录所用规则与 RiskLease 版本；接受结果必须建立或引用足额 RiskReservation。
_Avoid_: OrderCommand, mutable risk state, advisory score

**RiskLeaseChanged**:
RiskLease 被授予、续期、收紧、到期或撤销的不可变风险权限事实。
_Avoid_: PrimaryLease, config overwrite, heartbeat

**RiskReservationChanged**:
RiskReservation 被建立、调整或释放的不可变占用事实；当前占用总额由这些事实确定性投影。
_Avoid_: Balance transfer, mutable reservation row, RiskDecision

**OrderDispatchResult**:
执行网关对一次 OrderCommand 发送尝试产生的本地事实，只能证明未发送、已提交传输或结果不明，不能证明 Venue 已接受订单。
_Avoid_: ExecutionReport, Venue acknowledgement, transport log

**OrderReconciliationResult**:
使用明确查询范围和观察时点对 Unknown 或未完成 Order 得出的存在、终态、不存在或仍不确定事实；只有明确不存在才允许既定恢复规则继续。
_Avoid_: ExecutionReport, guessed absence, OrderState overwrite

**ConfirmedAbsent**:
在旧发送会话已静止、Venue 可见性延迟已满足且订单、终态、成交及经济事实查询范围完整时，证明某次 Unknown 提交未形成 Venue Order 的对账结论。
_Avoid_: Not Found response, missing open order, retry permission without evidence

## Markets

**Venue**:
提供交易、账户及市场事实的中心化交易所。
_Avoid_: Exchange name, market

**VenueAdapter**:
在 Execution Gateway 与某个 Venue 或 SimulatedVenue 之间接收规范 OrderCommand、订单对账及账户对账请求，输出 OrderDispatchResult 与外部事实的执行角色；它隐藏认证、传输、重连、对账和 Venue 字段，调用方不能绕过它直接发送订单。
_Avoid_: Exchange client, transport wrapper, Venue plugin

**MarketFeedAdapter**:
在 Venue 公共行情与交易核心之间输出规范市场事实的接入角色；它独立于 ExchangeAccount 生命周期并隐藏订阅、重连、快照恢复和 Venue 字段。
_Avoid_: VenueAdapter, market-data client, public WebSocket wrapper

**AdapterSessionIdentity**:
一次固定绑定 Venue、环境、ExchangeAccount 与 TradingCredential 的 VenueAdapter 运行身份；凭证、账户或环境改变必须创建新身份。
_Avoid_: Process id, connection id, ConfigVersion

**Asset**:
可以持有、结算或计价的经济资产。
_Avoid_: Currency, coin

**AssetAmount**:
以某个 Asset 的已激活原子精度表示的整数金额；离开适配器后的权威资金、费用和损益不得使用浮点或无 Asset 的裸数值。
_Avoid_: Money, decimal string, global micros

**Instrument**:
某个 Venue 上可交易的具体产品，其身份包含产品类型、相关 Asset 及合约规格；交易所字符串代码不是其权威身份。
_Avoid_: Symbol, pair, market

**InstrumentRules**:
在明确生效期间内适用于某个 Instrument 的版本化交易规则，包括交易状态、价格与数量约束、合约及结算规则。
_Avoid_: Current metadata, timeless symbol config

**InstrumentPrice**:
按明确 InstrumentRulesVersion 表示的整数价格单位；Venue 小数只有可被该规则精确表达时才能转换为 InstrumentPrice。
_Avoid_: Float price, price_micros, Venue decimal string

**InstrumentQuantity**:
按明确 InstrumentRulesVersion 表示的整数数量单位；它不能脱离 Instrument 与合约规格解释。
_Avoid_: Float quantity, raw size, universal lot

**InstrumentDefinitionObserved**:
适配器从 Venue 观察并标准化的产品身份、交易状态及规则候选事实；它在经验证的 ConfigEvent 生效前不能直接替换当前 InstrumentRules。
_Avoid_: InstrumentRules activation, web page scrape, mutable symbol metadata

**L2BookSnapshot**:
Venue 在明确来源序号上声明的某个 Instrument 完整价位级买卖盘事实，用于建立或重建权威 L2 订单簿。
_Avoid_: BBO, BookCheckpoint, local order book

**L2BookDelta**:
Venue 对某个 Instrument 的价位级数量变更事实，具有可验证的来源序号衔接；只有衔接到有效快照后才能改变权威 L2 订单簿。
_Avoid_: Full snapshot, derived depth, unordered update

**MarketTrade**:
Venue 公开行情中的市场成交，不表示本系统参与其中。
_Avoid_: Trade, Fill

**ReferencePrice**:
Venue 针对某个 Instrument 发布的标记价格或指数价格事实；两种价格必须明确区分，不能互相回退替代。
_Avoid_: Last trade, valuation route, generic market price

**FundingRatePublished**:
Venue 为某个永续 Instrument 发布的资金费率、适用区间及结算时点事实；它不是账户实际发生的 FundingSettlement。
_Avoid_: FundingSettlement, estimated rate, annualized yield

**Fill**:
Venue 或 SimulatedVenue 确认本系统某个 Order 已执行的一次唯一成交事实；它继承该订单的 ExchangeAccount 与 VirtualPortfolio 归属，并明确区分真实与模拟来源。
_Avoid_: Trade, ExecutionReport

**ExchangeBalanceSnapshot**:
Venue 在明确范围、来源游标和时点声明的 ExchangeAccount 完整资产余额事实；它用于对账，不能作为覆盖本地账本的命令。
_Avoid_: PortfolioBalance, ledger overwrite, balance delta

**ExchangeBalanceObserved**:
Venue 对 ExchangeAccount 中单个 Asset 最新绝对余额的不可变观察；它必须衔接有效 BootstrapSnapshotIdentity，不能表达数值差或直接覆盖本地账本。
_Avoid_: Balance delta, ExchangeBalanceSnapshot, ledger correction

**ExchangePositionSnapshot**:
Venue 在明确范围、来源游标和时点声明的 ExchangeAccount 完整真实仓位事实；它用于核对 ExchangePosition，不能直接重分配 VirtualPortfolio 归属。
_Avoid_: PortfolioPosition, position overwrite, local projection

**ExchangePositionObserved**:
Venue 对 ExchangeAccount 中单个 Instrument 与 PositionSide 最新绝对持仓的不可变观察；它只有衔接有效 BootstrapSnapshotIdentity 和连续来源序列时才能推进 ExchangePosition 投影。
_Avoid_: Position delta, ExchangePositionSnapshot, PortfolioPosition

**ExchangeMarginSnapshot**:
Venue 在明确时点声明的保证金余额、风险档位、维持保证金及强平参考值集合，用于保证金状态对账。
_Avoid_: MarginRules, PortfolioMarginBuffer, inferred liquidation model

**ExchangeMarginObserved**:
Venue 对 ExchangeAccount 或逐仓 Instrument 最新绝对保证金状态的不可变观察；它不能替代 MarginRules 或由本地风险模型反推。
_Avoid_: Margin delta, ExchangeMarginSnapshot, calculated margin

**VenueAccountConfigurationSnapshot**:
Venue 声明的账户持仓模式、保证金模式、杠杆和自动追加保证金等交易配置事实，用于安全准入与对账。
_Avoid_: ConfigEvent, desired configuration, local defaults

**VenueForcedExecution**:
Venue 在没有本系统 Order 的情况下产生的强平、ADL 或其他强制成交事实；它直接改变 ExchangePosition，不能伪造 OrderIntent、OrderCommand 或 Order。
_Avoid_: Fill, VenueAdjustment

**ForcedExecutionAllocation**:
把 VenueForcedExecution 的数量、损益、费用和罚金按强制执行前同方向 PortfolioPosition 的贡献确定性归属到 VirtualPortfolio 的事实；全部分配必须精确闭合。
_Avoid_: Fill, guessed attribution

## Simulation

**ResearchBacktest**:
使用聚合或简化市场数据快速检验策略逻辑与参数的研究运行；其结果不能作为与实盘可比较的生产资格证据。
_Avoid_: Production backtest, realistic simulation

**L2ReplayBacktest**:
使用完整且健康的历史 L2、市场成交及相关市场事实进行的确定性离线运行；它是首版历史回测的最高生产验收等级，但不声称重建不可观察的真实订单队列或自身市场冲击。
_Avoid_: Tick backtest, exact replay

**ShadowSimulation**:
使用实时生产市场事实、但不向 Venue 发送订单的仿真运行；其虚拟执行与 L2ReplayBacktest 采用相同语义。
_Avoid_: Paper account, testnet trading

**TestnetRun**:
在 Venue 测试环境中验证适配器协议、订单生命周期及恢复行为的运行；其市场与收益结果不具备 ComparableRun 资格。
_Avoid_: ShadowSimulation, production calibration

**SimulatedVenue**:
在回测或仿真中接收真实 OrderCommand 语义并产生模拟 ExecutionReport 与 Fill 的执行角色；它不能改变历史或实时外部市场事实。
_Avoid_: Strategy mock, fake OMS

**QueueAhead**:
模拟被动订单在某价位前方尚须由匹配方向 MarketTrade 消耗的数量；首版不因不可辨识归属的 L2 撤单而减少。
_Avoid_: Exact queue position, visible level size

**LatencyProfile**:
描述行情、策略、核心、网关、网络及 Venue 处理各段延迟的版本化经验模型；模拟抽样必须使用显式种子，且订单只在模拟到达时参与执行。
_Avoid_: Constant sleep, wall-clock runtime

**FeeSchedule**:
在明确生效期间内适用于某个 Venue、产品及账户费率等级的版本化手续费与返佣规则。
_Avoid_: Flat slippage, zero-fee assumption

**SimulationScenario**:
一组版本化、可重复的外部条件或故障注入规则，用于验证断连、乱序、Unknown 和恢复行为；它不与默认 PnL 回测的市场假设混合。
_Avoid_: Random chaos, market dataset

**ReplayDataset**:
L2ReplayBacktest 使用的不可变市场事实集合及完整性清单；其身份覆盖来源、时间范围、内容哈希、序号连续性、健康区间及必要市场事实的缺失情况。
_Avoid_: Mutable history, repaired-in-place data

**ReplayOrder**:
生产原始接入日志记录的市场事实可观察顺序；它保留各来源序号及实际跨来源合并次序，不能由 source_time 事后全局重排。
_Avoid_: Exchange-time sort, corrected chronology

**CaptureClockDomain**:
为多个市场数据来源提供共同单调接收时序及可验证误差界限的采集时钟范围；跨 Venue 可比较性不能仅由各自 source_time 建立。
_Avoid_: Exchange clock, wall-clock label

**RunManifest**:
唯一描述一次回测或仿真条件的不可变清单，至少标识策略构建产物、运行环境、参数、ReplayDataset、执行模型、FeeSchedule、LatencyProfile、SimulationScenario 及随机种子版本。
_Avoid_: Log header, mutable run config

**WarmupPeriod**:
正式统计区间之前用于从更早市场事实建立订单簿、指标、定时器及策略状态的区间；期间不授予交易权限，其结果不计入收益指标。
_Avoid_: Hidden trading period, look-ahead window

**IsolatedRun**:
只运行一个 VirtualPortfolio 的回测或仿真，用于归因该策略自身行为；其结果不能与其他隔离运行简单相加推导组合表现。
_Avoid_: Portfolio simulation, production account replay

**PortfolioRun**:
同时运行计划共享同一生产 ExchangeAccount 的策略集合，并共同承受流动性、账户限额、风险权限、资金占用及策略间交互的回测或仿真。
_Avoid_: Sum of isolated backtests, strategy batch

**SeedSet**:
用于同一回测条件下重复抽样 LatencyProfile 等随机模型的版本化种子集合；可比较运行必须使用相同集合并报告结果分布。
_Avoid_: Best seed, implicit randomness

**ComparableRun**:
满足生产策略执行路径、运行范围、数据完整性、模型校准、状态闭合及确定性重放门槛的 L2ReplayBacktest 或 ShadowSimulation；只有 RunManifest 中明确声明的实验变量可以不同。
_Avoid_: Any backtest, similar configuration

**CalibrationProfile**:
通过真实生产订单与同步影子模拟结果的配对误差建立的版本化执行模型适用范围；它按 Venue、流动性、订单类型及规模限定可比较资格。
_Avoid_: Hand-tuned constants, universal fill model

## Research Data

**SourceArchive**:
从交易面封存的原始接入日志与分片决策日志集合；它不可变，是重新解析、审计和确定性重放的最终数据来源。
_Avoid_: Query table, derived market data

**ResearchDataset**:
从 SourceArchive 或其他版本化数据集确定性生成的研究派生数据，必须保留生成规则及上游身份，允许重建或淘汰。
_Avoid_: Source of truth, mutable spreadsheet

**DatasetManifest**:
描述一个已发布不可变数据集身份、范围、结构版本、分区、质量、血缘及保留规则的清单；发布后不能原地修改。
_Avoid_: Mutable catalog row, storage directory

**DatasetRef**:
对某个已发布 DatasetManifest 的稳定引用；物理文件路径、表名和存储引擎不属于其调用契约。
_Avoid_: Latest pointer, file path

**DatasetPartition**:
DatasetManifest 中按数据类别、权限域、Venue、Instrument 及 UTC 时间范围组织的不可变数据片段；其内部顺序、范围和内容校验必须明确。
_Avoid_: Mutable table partition, strategy copy

**DatasetQuality**:
DatasetManifest 对 Pending、Complete、Degraded 或 Invalid 状态以及缺口、重复、解析失败和时钟异常区间的版本化声明；修复必须产生新版本，不能改写原结论。
_Avoid_: Boolean valid flag, hidden cleanup

**DataSensitivity**:
数据集对公共、受限及高敏私有数据的分类；派生数据和 RunArtifact 必须继承全部上游中的最高敏感级别。
_Avoid_: File permission, report visibility

**KnowledgeCutoff**:
查询或派生数据允许使用事实的最晚可知时刻；它决定迟到与更正事实是否对该视图可见。
_Avoid_: EffectiveTime, query end time

**FeatureDataset**:
在每个特征时点仅使用 KnowledgeCutoff 之前已可见事实生成的 ResearchDataset，可作为策略或模型输入。
_Avoid_: LabelDataset, restated hindsight

**LabelDataset**:
允许使用特征时点之后事实生成的监督或评估目标数据；它必须与策略可读取的 FeatureDataset 隔离。
_Avoid_: Strategy input, point-in-time feature

**TransformationManifest**:
描述一个 ResearchDataset 的全部上游 DatasetRef、转换构建、参数、环境、随机性、验证结果及生成身份的不可变清单。
_Avoid_: Notebook cell, undocumented ETL

**RunArtifact**:
一次研究、回测或仿真的 RunManifest、决策事实、执行结果、账本、资格检查及报告集合，用于复现该次运行结论。
_Avoid_: ReplayDataset, temporary log

**RetentionPolicy**:
按数据类别规定热、温、冷保留期及引用保护的版本化生命周期规则；被保留对象引用的数据不得回收。
_Avoid_: Manual cleanup, storage quota

**BookCheckpoint**:
从权威 L2 Snapshot 与 Delta 确定性生成的完整订单簿定位点，用于缩短回放 seek；它不能替代上游市场事件。
_Avoid_: Authoritative order book, sampled depth

**TimeBucket**:
按 UTC epoch 对齐的半开时间区间及其派生统计；空区间必须保留缺失与健康状态，不能静默前向填充。
_Avoid_: Local-time candle, implicit gap fill

## Security and Operations

**SystemOwner**:
首版唯一拥有全部控制面人工操作权限的人类主体；高风险操作只要求 RiskWarning 确认，不划分人工授权等级或双人审批。
_Avoid_: Root account, strategy developer

**MachineIdentity**:
授予某个生产进程或自动化任务的独立、可撤销身份；交易核心、执行网关、控制面、研究和部署身份不能互换。
_Avoid_: Shared service account, host name

**RiskWarning**:
控制面在执行高风险操作前向 SystemOwner 展示对象、影响范围及后果的非授权性提示；普通确认即可继续。
_Avoid_: Step-up authentication, dual approval

**OwnerSession**:
SystemOwner 通过管理 VPN 或专用管理网完成主认证与 TOTP 后获得的限时控制面会话；会话内高风险操作不再要求二次认证。
_Avoid_: MachineIdentity, approval token

**TradingCredential**:
绑定唯一 Venue、ExchangeAccount、环境及用途的交易所身份凭证；生产交易凭证不得具有提现权限，也不得被策略或研究进程持有。
_Avoid_: Shared API key, withdrawal key

**SecretMaterial**:
能够认证、签名或恢复身份的敏感值；除加密凭证存储及授权进程锁定内存外不得出现，也永不进入日志和研究数据。
_Avoid_: credential_id, public key

**CredentialStore**:
保存加密 TradingCredential 的静态存储；首版由 SystemOwner 在节点启动时使用独立口令手工解密，TPM 自动解封只作为未来可选能力。
_Avoid_: Plaintext config, environment variable

**ObservationCredential**:
仅能读取 ExchangeAccount、订单、成交及仓位事实的 TradingCredential，用于对账、监控和热备预热，不能升级后继续复用为交易用途。
_Avoid_: ExecutionCredential, public market-data access

**ExecutionCredential**:
只允许执行网关读取账户事实并交易目标现货与永续产品的 TradingCredential；它不得移动资金或管理账户，并必须绑定授权节点、fencing token 与执行安全栅栏。
_Avoid_: ObservationCredential, trading authorization

**CredentialState**:
TradingCredential 的 Staged、Active、Retiring 或 Revoked 生命周期状态；Revoked 凭证不可通过配置回滚恢复。
_Avoid_: Secret version, process cache state

**ReleaseArtifact**:
带内容哈希、来源版本、依赖锁及验收结果的软件构建产物；生产只能加载经软件签名且已批准的版本。
_Avoid_: Source tree, unsigned binary

**OperatorRecord**:
SystemOwner 的人工操作实际改变生产状态时形成的精简记录；它不记录普通读取或提示，保留期由 RetentionPolicy 决定。
_Avoid_: Access log, trading event log

**ReleaseRecord**:
OperatorRecord 中对 ReleaseArtifact 批准、部署、回滚或签名密钥变更的发布专用记录。
_Avoid_: Build log, per-step audit stream

**DeployRelease**:
SystemOwner 对明确目标及 ReleaseArtifact 或 ConfigEvent 内容哈希一次确认后启动的完整受控发布命令；候选验证、排空和原子切换不再要求重复人工批准。
_Avoid_: Build command, multi-step approval workflow

**KillSwitch**:
按全局、Venue、ExchangeAccount、DecisionDomain 或 StrategyInstance 范围立即禁止新增风险并撤销存量挂单的安全状态；它不自动强制平仓。
_Avoid_: Flatten, process shutdown

**Flatten**:
DeRisk 的目标敞口为零时形成的受控减仓操作；它独立于 KillSwitch，并须先展示 RiskWarning。
_Avoid_: KillSwitch, automatic liquidation

**DeRisk**:
SystemOwner 明确发起、只允许 Reduce-only 订单把选定范围降至目标敞口的受控操作；未达到目标并完成对账前保持 Draining。
_Avoid_: KillSwitch, risk-limit update, automatic liquidation

**NodeFence**:
在提升热备前由旧节点之外的网络或凭证控制面建立的隔离事实，保证旧节点不能访问 Venue 私有交易端点。
_Avoid_: fencing token, process shutdown

**ControlCommand**:
控制面对明确目标签发的不可变状态变更命令，具有唯一身份、内容哈希、版本前置条件、有效期限及软件签名；重复命令不得重复生效。
_Avoid_: RPC call, mutable config request

**SecurityAdmission**:
执行网关获得交易权限前必须通过的身份、Artifact、凭证权限、账户配置、状态对账及节点隔离检查集合；失败时只允许降低风险。
_Avoid_: Health check, operator approval

**SecurityIncident**:
凭证、节点、控制面或 ReleaseArtifact 的可信性受到怀疑并要求先触发 KillSwitch 与隔离、再轮换和对账、最后由 SystemOwner 恢复的状态。
_Avoid_: Warning, automatic restart

**OperationalMode**:
某个 StrategyInstance、DecisionDomain 或 FailoverGroup 的运行阶段，只允许 Stopped、Recovering、Ready、Trading 和 Draining；它不编码行情、凭证、租约或 KillSwitch 等安全条件。
_Avoid_: Process state, combined health status

**SafetyGate**:
独立决定某个范围是否仍具备新增风险能力的安全条件，例如 KillSwitch、行情健康、凭证、PrimaryLease、RiskLease 和 fencing 状态；任一必需条件关闭即撤销新增风险能力。
_Avoid_: OperationalMode, warning

**SelfRecoveringGate**:
关闭期间不产生未知经济或身份事实、并能由系统确定性证明状态连续的 SafetyGate；重新验证通过后可以继承原 TradingAuthorization。
_Avoid_: LatchedSafetyGate, automatic failover

**LatchedSafetyGate**:
因订单、对账、凭证、主身份或持久状态可能不确定而撤销 TradingAuthorization 的 SafetyGate；原因消除后仍须由 SystemOwner 重新启用交易。
_Avoid_: SelfRecoveringGate, transient warning

**EffectiveTradingAuthority**:
某个 StrategyInstance 自身及其 DecisionDomain、FailoverGroup、ExchangeAccount 和全局 SafetyGate 共同允许的实际交易权限；任一上级限制都会向下收紧，解除上级限制不会清除子级锁存。
_Avoid_: OperationalMode, StrategyLimit

**TradingAuthorization**:
SystemOwner 通过 EnableTrading ControlCommand 授予某个 Ready 范围进入 Trading 的人工授权；它不能绕过 SafetyGate，只能由已获资格的自动故障恢复路径继承。
_Avoid_: RiskLease, login session, health check

**TradingPause**:
SystemOwner 对某个交易范围建立的持续停单状态；它停止新增风险、清空并对账未完成订单后使范围停在 Ready，但不自动平仓。
_Avoid_: Process suspension, KillSwitch, CancelOpenOrders

**CancelOpenOrders**:
撤销指定订单或范围内当前未完成订单的一次性 ControlCommand；它不改变 OperationalMode，处于 Trading 的策略之后仍可重新报单。
_Avoid_: TradingPause, KillSwitch

**KeepPositions**:
停止策略或交易节点时明确保留现有 PortfolioPosition 的停机处置选择；它不撤销经济归属，也不表示相关风险已经消失。
_Avoid_: Flatten, abandoned position

**ForcedStop**:
在撤单、对账或日志闭合尚未完成时强制终止运行的人工操作；它不构成正常 Stopped 证明，后续启动必须完整恢复和对账。
_Avoid_: Clean shutdown, KillSwitch

**LifecycleOperation**:
对明确目标执行 Pause、DeRisk、停机、发布或恢复的单个长生命周期操作；同一目标及其被锁定子范围同一时刻只能存在一个，KillSwitch 除外。
_Avoid_: Workflow, queued command batch

## Performance Qualification

**CoreDecisionLatency**:
TradingShard 取得一个已标准化事件至产生该事件最后一个相关 OrderIntent 的单调时间间隔；未产生意图的事件仍计入其核心处理分布。
_Avoid_: Strategy latency, average event time

**InternalOrderLatency**:
适配器收到可供用户态读取的数据至一个通过风控的订单报文完成序列化并可提交发送的单调时间间隔；它是内部订单路径的权威端到端性能合同。
_Avoid_: Exchange latency, network round trip

**PythonDecisionLatency**:
TradingShard 发布事件批次至该批次产生的 OrderIntent 返回并完成基础身份、新鲜度和 schema 验证的本机内部时间间隔；它不包含交易所网络、撮合或回报时间。
_Avoid_: Exchange latency, Python order round trip

**HardwarePathLatency**:
由 NIC RX/TX 硬件时间戳观察到的节点数据路径间隔，用于诊断内核、驱动和网卡开销，不替代 InternalOrderLatency。
_Avoid_: InternalOrderLatency, exchange round trip

**BenchmarkManifest**:
唯一描述一次性能资格运行的不可变清单，标识负载场景、数据或生成规则、随机种子、InstrumentRules、策略与软件构建、节点基线、运行配置及观测开销；身份不同的运行不能默认直接比较。
_Avoid_: Benchmark config, latest performance result

**QualificationReport**:
记录某个 ReleaseArtifact 在一个 BenchmarkManifest 下全部有效、失败及无效运行证据和最终资格结论的不可变报告；仍被生产基线、候选发布或事故调查引用时不得回收。
_Avoid_: Benchmark summary, best run

**TelemetryPublish**:
将本地聚合的性能分布、容量计数和健康状态异步发送到外部监控存储、仪表盘或告警通道；它不承载原始接入日志、分片决策日志、订单账本或 SecretMaterial。
_Avoid_: Trading log export, research data export

**ObservabilityDegraded**:
必需遥测在允许时限内无法成功发布的节点健康状态；本地交易安全判断继续有效，但持续失明会撤销新增风险权限。
_Avoid_: Trading halt, missing dashboard

## State Evolution

**AuthoritativeTradingState**:
订单、成交、持仓、账本、风险占用、配置版本和分片游标等决定真实经济结果的状态；它由权威事实、快照和日志恢复，不属于策略私有状态迁移。
_Avoid_: Strategy state, process memory

**StrategyPrivateState**:
策略为延续自身决策而保存的版本化状态，例如指标窗口和模型状态；只有它可以通过显式、确定性的状态迁移转换到新版本。
_Avoid_: Portfolio ledger, venue order, runtime object

**RebuildableState**:
可由权威输入重放、重新同步或预热得到的非权威状态，例如行情簿、指标缓存和其他派生数据；版本切换时优先重建而非逐字段迁移。
_Avoid_: AuthoritativeTradingState, StrategyPrivateState

**EphemeralRuntimeState**:
线程、指针、分配器内部状态、队列、连接和解释器对象等仅对当前进程有效的运行状态；它不得进入迁移载荷。
_Avoid_: Snapshot state, strategy checkpoint

**StateSchemaVersion**:
标识快照或 StrategyCheckpoint 中持久状态结构的版本；它与生成该状态的软件或策略版本、参数版本及分片序号共同记录，版本不匹配时不得猜测读取。
_Avoid_: Release version, config version

**StateMigration**:
将一个明确 StateSchemaVersion 的 StrategyPrivateState 确定性转换为目标版本的纯函数；不存在明确迁移或迁移失败时，目标策略不得激活。
_Avoid_: Best-effort deserialization, runtime object migration

**CanonicalStateDigest**:
在同一分片屏障上对订单、成交、持仓、账本、风险占用和游标等 AuthoritativeTradingState 计算的稳定摘要；状态迁移不得改变其结果。
_Avoid_: Serialized byte hash, strategy output comparison

**StrategyStateTransition**:
策略版本或参数版本切换时对 StrategyPrivateState 采取的明确方式，仅允许 Keep、Migrate 或 Rebuild；Rebuild 未完成预热和验证前策略不得产生 OrderIntent。
_Avoid_: Implicit compatibility, best-effort state reuse

**CutoverDrain**:
代码或参数版本切换前，对受影响范围的全部未完成订单完成撤销和 Venue 对账的阶段；存在 Unknown 订单时目标版本不得增加风险。
_Avoid_: Process shutdown, best-effort cancel

**ForwardRollback**:
在保留当前订单、成交、持仓、账本和分片进度的前提下，把旧代码作为新的候选版本重新切入；它是一次新的正向版本切换，而不是恢复旧经济状态。
_Avoid_: Snapshot restore, ledger rollback, version rewind

**CutoverBarrier**:
受影响范围停止产生新 OrderIntent、完成 CutoverDrain，并在同一 shard sequence 上原子替换活动代码版本、参数版本和策略状态引用的切换边界。
_Avoid_: Wall-clock switch, rolling state mutation

**PortableStrategyState**:
Python 策略 checkpoint 中仅由显式 schema 定义、可稳定编码的基础数据组成的 StrategyPrivateState；V1 使用 PortableStrategyStateJsonV1，它不得包含 pickle、marshal、解释器对象或任意对象图。
_Avoid_: Python object snapshot, process image

**StrategySuccessor**:
策略代码变化或 ForwardRollback 时创建的新 StrategyInstance；它接替旧实例的交易权限并延续同一 VirtualPortfolio，但拥有新的实例身份和 OrderIntent 身份空间。
_Avoid_: Resurrected instance, new portfolio

**VersionActivationEvent**:
在 CutoverBarrier 上确定旧版本失权、新版本取得权威身份的不可变分片事件；它记录版本、实例、状态转换、schema、摘要和序号，并须在授予新增风险权限前持久化且由热备确认。
_Avoid_: Deployment log, mutable active-version flag

## Availability and Recovery

**FailoverCause**:
触发或考虑主备切换的规范故障分类，区分 PlannedSwitch、ProcessFailure、NodeFailure、NetworkPartition 与 UntrustedState；Venue 自身中断属于外部降级，不是本地主备故障。
_Avoid_: Generic outage, venue downtime

**EconomicRPO**:
故障后对已在 Venue 生效或已被系统确认生效的经济与控制事实允许永久丢失的范围；本系统要求为零，并通过身份、对账和幂等账务恢复，不等同于热路径同步刷盘。
_Avoid_: Disk flush RPO, replay tail

**ReplayRPO**:
故障后无法按原 shard sequence 精确重建的内部决策日志尾部；它不允许掩盖 Venue 事实，存在缺口时相关策略状态必须重新取得资格。
_Avoid_: EconomicRPO, capture gap

**HADegraded**:
热备重放落后超过 ReplayRPO 正常上限、因而不再具备自动提升资格的可用性状态；主节点可短时保持唯一主身份，但持续退化会撤销新增风险权限。
_Avoid_: Primary failure, automatic failover

**SafetyRTO**:
从故障被检测到旧主不能再增加风险的最长允许时间；它不表示新主已经具备交易资格。
_Avoid_: TradingRTO, failover duration

**TradingRTO**:
从当前主实例失去新增风险能力到新主完成隔离、状态恢复、对账和安全准入并重新获得新增风险权限的时间。
_Avoid_: SafetyRTO, process restart time

**PrimaryLease**:
授予唯一主实例的短期、可续期交易身份权限，绑定 ExchangeAccount、DecisionDomain 和 FencingToken；过期即失去增加风险的权力。
_Avoid_: RiskLease, process heartbeat

**FencingToken**:
由交易节点外部权威为 PrimaryLease 分配的严格递增且永不复用的主身份代次；执行网关拒绝非当前代次的订单命令。
_Avoid_: NodeFence, RiskLease version

**RecoveryOnly**:
候选或恢复中的主实例只能撤单、Reduce-only 和对账的交易权限状态；它尚未通过 FailoverAdmission，不能增加风险。
_Avoid_: Active, read-only standby

**FailoverAdmission**:
候选主获得新增风险权限前必须同时证明的身份隔离、软件配置、重放状态、Venue 对账、市场风险和节点健康条件集合。
_Avoid_: Health check, heartbeat

**FailoverGroup**:
因共享执行网关、ExecutionCredential、节点隔离或账户对账而必须共同停止、隔离或切换的一组 DecisionDomain；它可以大于单个 DecisionDomain。
_Avoid_: TradingShard, ExchangeAccount

**FailoverReport**:
记录一次故障测试、实际故障或主备切换的 FailoverCause、隔离证据、RTO/RPO、对账结果、准入结论及全部失败事实的不可变报告。
_Avoid_: Incident summary, success-only drill log
