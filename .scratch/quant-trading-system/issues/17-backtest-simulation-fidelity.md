# 定义回测和仿真保真等级

Type: grilling
Status: resolved
Blocked by: 13, 15
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

第一版回测与仿真需要模拟哪些撮合、排队、滑点、手续费、资金费率、延迟、部分成交和强平行为，哪些结果可以被称为可比较？

## Answer

规范回测与仿真词汇记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### Fidelity levels

- ResearchBacktest 使用 K 线、成交或简化 BBO 数据快速筛选逻辑与参数；允许简化成交、费用及滑点假设，其结果不能作为与实盘可比较的生产资格证据。
- L2ReplayBacktest 离线重放完整、健康的历史 L2、MarketTrade、标记/指数价格和资金费率，通过虚拟时钟与 SimulatedVenue 运行生产同一订单、风控、账本及策略核心；它是首版历史回测的最高生产验收等级。
- ShadowSimulation 使用实时生产市场事实但不向 Venue 发送订单，采用与 L2ReplayBacktest 相同的 SimulatedVenue 语义，是上线前时序、延迟和运行稳定性验收等级。
- TestnetRun 只验证适配器协议、鉴权、签名、限流、订单生命周期、断线恢复和对账。测试网流动性、延迟和收益不具备 ComparableRun 资格，也不能进入生产 CalibrationProfile。

### L2 execution and queueing

- 市价单和主动限价单在模拟到达 SimulatedVenue 时，按当时健康 L2 逐档消耗可见深度并生成逐价位 Fill；深度不足时按目标 Venue 的 TIF 语义部分成交、排队或取消。
- Post-only 到达时若会立即成交，则按对应 Venue 规则拒绝或取消。
- 被动限价单默认排在到达时该价位全部可见数量之后，本系统模拟订单按稳定接受顺序排队。
- QueueAhead 只由方向匹配的 MarketTrade 消耗；首版不因无法辨识归属的 L2 撤单而减少，市场成交明确穿过价位时才可判定该队列已被消耗。
- Gap、Stale 或成交方向信息不足时禁止推测成交。
- 同一 Venue/Instrument 的全部模拟策略共享一份市场成交量预算，不能重复领取同一公开成交。
- SimulatedVenue 不修改后续历史或实时外部盘口，因此首版不模拟自身市场冲击；只有订单规模低于 CalibrationProfile 规定的盘口及成交量占比上限时才具备可比较资格。

### Latency model

- LatencyProfile 分别描述行情接入、策略决策、核心与风控、出站网关、网络、Venue 处理及回报接入延迟。
- L2ReplayBacktest 优先重放已记录的 source_time 与 receive_time；无法直接观测的链路按 Venue、产品、订单类型和策略运行方式使用版本化生产经验分布。
- 原生策略和 Python Strategy Host 使用各自生产采样的延迟分布；全部抽样由 RunManifest 中的显式 SeedSet 驱动。
- 订单只在模拟到达 Venue 的时间看到当时盘口并进入队列，不能用策略决策时的盘口立即成交。
- ExecutionReport 与 Fill 按回程延迟到达核心，策略在收到事实前不能观察结果。
- ShadowSimulation 使用真实行情接入和本地处理时间，只模拟未实际发送部分的网络、Venue 与回报链路。
- 虚拟时间不依赖回测机器的实际计算速度。保守默认分布只可用于研究，ComparableRun 必须使用生产校准模型。

### Fees, funding and slippage

- L2ReplayBacktest 不叠加固定百分比滑点；买卖价差、逐档吃单、QueueAhead 和 LatencyProfile 共同产生模拟成交价。
- FeeSchedule 按历史生效时间记录 Venue、产品、账户等级、maker/taker、扣费 Asset 及返佣规则。无法确定等级时使用明确的保守等级，禁止默认零费用。
- 资金费使用历史结算时点、已公布费率、标记价格及合约规格，并按 FundingSettlement 与 FundingAllocation 的既定语义处理。
- 资金费数据缺失时，覆盖该结算时点的永续运行失去比较资格，禁止静默插值。
- ResearchBacktest 可以使用固定滑点与简化费用，但报告必须明确标识研究假设。

### Order lifecycle

- SimulatedVenue 在订单到达时按历史有效 InstrumentRules 校验交易状态、价格步长、数量步长、最小名义金额、余额及 Venue 限制，不合法订单生成 Rejected。
- 每次部分成交产生独立 Fill 与 ExecutionReport，不能在结束时只生成汇总成交。
- IOC 可部分成交后取消余量；FOK 只在到达时全量可成交时执行；GTC 未成交余量继续排队。
- 撤单经历完整延迟并与期间成交竞争，撤单确认不能抹掉已发生 Fill。
- 改单按目标 Venue 能力处理；原生 amend 是否保留队列优先级由当时规则决定，否则使用 cancel-and-new 并失去优先级。
- Venue 侧事实保持因果顺序，回报链路允许 ACK、Fill 和撤单结果以不同延迟到达核心；同一虚拟时间使用稳定序号打破平局。
- 断连、丢包、乱序和 Unknown 通过版本化 SimulationScenario 重复验证，不随机混入默认 PnL 运行。

### ReplayDataset integrity

- 每次 L2ReplayBacktest 绑定不可变 ReplayDataset 清单，记录内容哈希、Venue、Instrument、时间范围、来源序号覆盖、快照、L2 增量、MarketTrade、标记/指数价格及资金费完整性。
- 回放必须复现 Live、Gap、Stale、Recovering 等健康状态，不能直接拼接缺口两端订单簿。
- 缺口期间禁止依赖该盘口新增风险。生产资格数据不得静默补齐；任何修复形成新的版本化数据集。
- 缺口期间存在活动模拟订单或相关持仓时，整次运行失去可比较资格。没有相关暴露且所有比较运行使用相同数据和健康事件时可继续比较，但必须披露缺口区间。

### Liquidation and exceptional events

- 策略、本地风控与账本继续运行生产同一核心；具体保证金及强平公式由[定义保证金归属、强平距离与抵押品边界](28-margin-liquidation-and-collateral.md)产出的版本化规则提供。
- SimulatedVenue 独立计算交易所侧保证金状态，不能假定本地风控必然阻止强平。
- 标记价格触及保守强平阈值时，先撤销相关挂单，再按当时 L2 模拟强制减仓；成交、强平费用及其他 VenueAdjustment 分别记录。
- 公开规则不足时使用明确保守缓冲，不宣称精确复制 Venue 私有强平引擎。
- ADL、保险基金分摊和穿仓只通过 SimulationScenario 做压力测试，不混入默认历史 PnL。
- 发生模拟强平的运行保留全部分析结果，但自动判定为未通过生产策略资格。

### Production strategy path

- 原生策略使用与实盘相同的 StrategyDefinition 构建产物并在 TradingShard 内运行。
- Python 策略通过与实盘相同的独立 Strategy Host、序列化协议及 IPC 通道运行；生产资格回测不能改为核心内直接调用。
- 策略只能接收事件、TimerEvent 和受控配置，不能读取回测文件、未来虚拟时间或预计算未来指标。
- 回测机器的计算耗时不推进虚拟市场时间，模拟订单生效时间由 LatencyProfile 决定。
- 向量化或重写策略只属于 ResearchBacktest；策略构建产物、Python 环境、参数及状态初始化版本进入 RunManifest。

### Start, warmup and end

- 资格运行从显式 OpeningBalance、零仓位和零挂单开始，初始资金及 VirtualPortfolio 归属记录在 RunManifest。
- WarmupPeriod 使用同一 ReplayDataset 的更早事件建立 L2、指标、TimerEvent 和策略状态，但不授予交易 RiskLease；期间产生的 OrderIntent 确定性拒绝。
- 只有必需订单簿为 Live、策略状态就绪、估值源健康并满足预热要求后，才通过可重放启用事件开始交易及统计。
- 历史状态快照只能来自相同策略与配置版本、更早事件的确定性结果，并在 RunManifest 中标识。
- 到达统计终点后停止新策略决策，只处理终点前已经进入系统且模拟到达时间不晚于终点的事件。
- 不强制平仓；剩余仓位使用终点最后一个健康 ValuationSnapshot 计算 UnrealizedPnL。清理撤单不进入本次 PnL。
- 终点存在 Unknown、Unvalued 或必要行情不健康时，不能发布完整可比较 PnL。需要全部退出的策略必须在终点前通过可重放停止事件自行执行。

### Isolated and portfolio runs

- IsolatedRun 一次只运行一个 VirtualPortfolio，用于策略自身归因、参数比较和回归。
- PortfolioRun 同时运行计划共享生产 ExchangeAccount 的完整策略集合，保留真实 DecisionDomain 分片、全局风险额度、账户限制和共享 SimulatedVenue。
- PortfolioRun 中策略共享流动性、QueueAhead、资金占用和 FundingAllocation；跨 DecisionDomain 命令按已记录稳定合并顺序进入执行。
- 自成交防护、账户仓位净额及策略交互必须在 PortfolioRun 中生效。IsolatedRun 收益不能相加推导组合收益。
- 上线前策略必须同时通过 IsolatedRun 和目标账户 PortfolioRun；只有相同运行范围结果可直接比较。

### ComparableRun contract

- ComparableRun 只能是使用生产策略路径的 L2ReplayBacktest 或 ShadowSimulation。
- 比较双方运行范围相同，RunManifest 除明确声明的实验变量外保持一致，包括 ReplayDataset、初始资本、风险限制、FeeSchedule、LatencyProfile、执行模型及 SeedSet。
- 数据完整性必须合格，订单规模位于 CalibrationProfile 适用范围内，且不存在未解决 Unknown、ReconciliationBreak、Unvalued、暴露期间行情缺口或模拟强平。
- 相同 RunManifest 与种子重跑时，决策日志、Fill、账本和最终状态摘要必须一致。
- 报告至少包含净 PnL、最大回撤、RealizedPnL、UnrealizedPnL、TradingFee、TradingRebate、FundingAllocation、换手率、敞口、资金占用、maker/taker 比例、成交率、部分成交率、拒单率及订单延迟。
- 多种子资格报告展示完整分布，不能挑选最好种子；不同时间区间或市场条件只能并列展示，不能直接宣称策略改进。

### Calibration

- 对真实生产 OrderCommand 同步生成不影响 Venue 的影子模拟订单，并与真实 ExecutionReport 和 Fill 配对。
- 校验接受/拒绝、成交与否、部分成交、maker/taker、成交价格、等待时间、费用及回报延迟。
- CalibrationProfile 按 Venue、Instrument 流动性分组、订单类型及规模分桶记录样本区间、样本量、误差分布与适用范围。
- QueueAhead、LatencyProfile 和流动性占比上限只能根据生产样本更新，每次更新形成新模型版本。
- 校准数据与验收数据使用不重叠时间区间；超出适用范围或误差超过验收阈值的运行降级为研究结果。

### Historical ordering and point-in-time rules

- L2ReplayBacktest 按生产原始接入日志的 ReplayOrder 回放，不按 source_time 对 L2、MarketTrade、标记价格及资金费进行事后全局排序。
- 每个来源保留 source_seq；跨连接与数据类型的实际合并次序由原始日志位置或已记录 shard 输入序号确定。重复、乱序及健康变化保持原样。
- TimerEvent、模拟订单到达及模拟回报按虚拟单调时间插入，并以稳定序号处理同一时刻事件。
- 只有交易所时间而无可靠接收顺序的数据只能用于 ResearchBacktest。
- InstrumentRules、白名单、FeeSchedule、交易状态、步长、最小金额、合约乘数、结算规则及资金费周期按历史生效时间重放。
- 上市、暂停、恢复和下架通过版本化事件进入核心；缺少历史规则时不得用当前元数据静默补齐。

### Cross-Venue clock qualification

- 跨 Venue 原始行情必须位于同一 CaptureClockDomain，或保存经过校准的时钟偏移与不确定度。
- RunManifest 记录采集节点、时钟源、同步状态、最大误差及中断区间；不得仅凭各 Venue 的 source_time 合并事件。
- 当时钟不确定度大于策略利用的跨 Venue 时间优势时，该运行不能评价跨所延迟策略，只能用于较低频逻辑。
- 独立下载的数据即使各 Venue 内完整，也不能成为跨 Venue ComparableRun，除非跨源时序误差具有可验证界限。

### Acceleration boundary

- L2ReplayBacktest 可以远快于真实时间运行，但虚拟事件顺序与时间间隔保持不变。
- 解压、读取、校验、报告生成及多个独立 RunManifest 可以异步并行。
- 单个 DecisionDomain 仍由同一单写者核心顺序处理；PortfolioRun 保留四个 DecisionDomain 的生产分片语义，跨分片结果只按稳定合并顺序提交。
- 禁止批量替代策略调用、合并不可推导事件、跳过 TimerEvent 或使用向量化替代生产路径。
- 回测吞吐与实盘延迟是独立指标；优化优先落在 ReplayDataset 解码及独立运行并行，不建设第二套语义不同的高速回测引擎。

## Comments

- 2026-07-26：经逐项回测与仿真保真访谈确认并解决；完整建议保存在本 Answer，地图仅保存索引摘要。
