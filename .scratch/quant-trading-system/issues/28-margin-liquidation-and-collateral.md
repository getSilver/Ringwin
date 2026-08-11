# 定义保证金归属、强平距离与抵押品边界

Type: grilling
Status: resolved
Blocked by: 05, 14, 15
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

在首版 USDT 线性永续、单向持仓和逐仓保证金范围内，VirtualPortfolio 应如何拥有及占用保证金、计算初始与维持保证金和强平距离、处理多个投资组合共享 ExchangeAccount 的风险，并为未来组合保证金与跨币种抵押品保留什么明确边界？

## Answer

### 双层保证金所有权与占用

- USDT 始终由 PortfolioBalance 表示所有权；保证金不是一份新的资产余额。
- 每个 VirtualPortfolio 按 Instrument 建立 PortfolioMarginReservation，占用其自身 USDT，用于持仓初始保证金、未完成增仓订单和费用缓冲。占用本身不产生账务支出或资产转移。
- Venue 实际逐仓保证金属于 ExchangeAccount + Instrument 的 ExchangeMarginBucket。Venue 不识别 VirtualPortfolio，因此该真实保证金桶不能声明由某个策略独占拥有。
- 每个 VirtualPortfolio 按自身归属仓位和挂单毛额计算保证金，不使用其他 VirtualPortfolio 的反向仓位抵消。
- 执行网关同时验证 VirtualPortfolio 虚拟保证金和 ExchangeAccount 在 Venue 的真实净仓位及保证金。
- TreasuryPortfolio 可以保留账户级安全缓冲，但该缓冲不进入任何 StrategyLimit，也不能被策略静默借用。

### 初始保证金与挂单占用

- 每个 Venue + Instrument + 账户模式提供版本化 MarginRules，包含合约乘数、风险档位、初始与维持保证金率、最大杠杆、扣减额、费用和舍入规则；不假设四家 Venue 共用一条公式。
- VenueInitialMargin 按适配器复现 Venue 当前规则；InternalInitialMargin 在其上加入内部安全缓冲，且不得低于 VenueInitialMargin。
- 每个 VirtualPortfolio 独立按自身 PortfolioPosition 和普通挂单的最坏方向计算。对当前仓位 q、未完成买入量 B 和卖出量 S，评估买单先成交和卖单先成交后的最大绝对敞口，不让相反挂单静态抵消。
- 有效 Reduce-only 订单不增加仓位保证金，但仍预留可能产生的 TradingFee。
- Market 订单使用受保护的最坏成交价格；Limit 订单使用限价与保守风险价格中更不利者。
- PortfolioMarginReservation 至少覆盖最坏持仓 InternalInitialMargin、全部可能成交费用和明确安全缓冲。
- 全部权威金额使用定点整数，并向增加保证金要求的方向取整；f64 不参与计算。

### 维持保证金与健康度

- PortfolioMarginEquity 是某个 VirtualPortfolio 在该 Instrument 已占用的保证金加按 Venue 标记价格计算的 UnrealizedPnL。已结算 TradingFee、FundingAllocation 和 RealizedPnL 通过 PortfolioBalance 影响它，不加入未来资金费估计。
- InternalMaintenanceMargin 按该 VirtualPortfolio 毛持仓及当前 MarginRules 风险档位计算，并且不得低于对应 Venue 维持保证金要求。
- PortfolioMarginBuffer = PortfolioMarginEquity - InternalMaintenanceMargin - 预计平仓手续费或强平费用缓冲。
- ExchangeAccount 另按 Venue 报告的 ExchangeMarginBucket、净 ExchangePosition、标记价格和风险档位计算 ExchangeMarginBuffer。
- 安全判断取两层中更差的结果：VirtualPortfolio 充足不能覆盖真实账户危险，真实账户净额安全也不能允许某个投资组合超用资本。
- MarginBuffer 是权威安全量；各 Venue 含义不一致的保证金率百分比只用于展示。
- 标记价格、MarginRules 或 Venue 仓位/保证金状态缺失、过期或矛盾时，健康度为 Unknown，禁止新增风险并进入对账。
- PortfolioMarginBuffer 或 ExchangeMarginBuffer 低于内部阈值时触发对应范围 KillSwitch 并告警，只允许撤单和 Reduce-only，不自动 Flatten。

### 强平阈值与距离

- PortfolioLiquidationThreshold 固定当前虚拟持仓、PortfolioMarginReservation 和 MarginRules，让标记价格沿不利方向变化，取首次使 PortfolioMarginBuffer 不大于零的价格。
- ExchangeLiquidationThreshold 对 Venue 真实净 ExchangePosition 和 ExchangeMarginBucket 计算，并与 Venue API 报告的强平价格并列保存。
- VirtualPortfolio 方向相反时，各自的 PortfolioLiquidationThreshold 只是内部风险阈值；只有 ExchangeLiquidationThreshold 对应 Venue 真实强平风险。
- 不为四家 Venue 建立统一闭式公式；使用同一保证金函数按价格 tick 确定性分档求解，覆盖风险档位切换、扣减额、费用和 Venue 舍入。
- LiquidationDistance 以当前标记价格到阈值的不利方向 tick 数和基点表示：多仓为 mark - threshold，空仓为 threshold - mark。
- 零仓位没有 LiquidationDistance；规则或价格不完整时结果为 Unknown，不能表示为零或无限大。
- 本地 ExchangeLiquidationThreshold 与 Venue 报告值超过适配器容差时形成风险对账异常并禁止新增风险，不能静默选择较安全的值。
- 风险准入使用更保守阈值，并在 Venue 强平线之前触发 KillSwitch 和人工 DeRisk。

### 杠杆与保证金调整

- ExchangeAccount + Instrument 只有一个 Venue 杠杆设置；共享真实逐仓仓位的 VirtualPortfolio 不得各自修改交易所杠杆。
- Venue 杠杆由版本化 MarginRules 固定为保守值；VirtualPortfolio 可以有更低的内部最大杠杆，但不能要求更高的 Venue 杠杆。
- Venue 自动追加保证金必须关闭并在启动时验证，禁止亏损仓位自动扫取整个 ExchangeAccount 的可用 USDT。
- 价格不利变化不会自动扩大 PortfolioMarginReservation，避免逐仓语义退化为静默使用全部 PortfolioBalance。
- 增加保证金只能来自该 VirtualPortfolio 自身未占用 USDT，或由 SystemOwner 先通过 PortfolioTransfer 转入该投资组合。
- 每次增加或释放形成 MarginAdjustment，记录资金所有者、目标 Instrument、金额、前后 MarginBuffer 和 MarginRules 版本。
- 移除保证金后两层 MarginBuffer 仍须高于内部阈值，并且不存在挂单、Unknown Order 或 ReconciliationBreak；释放回原资金所有者。
- 保证金不足时默认触发 KillSwitch 并允许 Reduce-only，不自动从 TreasuryPortfolio 补充，也不自动 Flatten。

### 共享账户的净额收益

- GrossPortfolioMargin 是同一 ExchangeAccount 内全部 VirtualPortfolio 的 PortfolioMarginReservation 之和，不跨策略抵消。
- VenueNetMargin 按净 ExchangePosition 和 ExchangeMarginBucket 计算。
- AccountNettingBenefit 是 GrossPortfolioMargin 高于 VenueNetMargin 的差额，只表示 Venue 当前少占用的真实保证金；它不属于任何策略，不进入 PortfolioBalance、StrategyLimit 或可提现余额。
- ExchangeAccount 可用 USDT 必须覆盖 GrossPortfolioMargin、全部订单费用占用及 Treasury 安全缓冲，不能只覆盖 VenueNetMargin。
- 新订单准入同时模拟目标 VirtualPortfolio 最坏毛仓位、全部相关订单成交后的 Venue 净仓位，以及任一投资组合单独退出后重新出现真实仓位所需的保证金。
- 最坏退出场景无法由现有账户资金支持时拒绝继续增加风险，即使当前 ExchangePosition 为零。
- 仓位与资金对账要求 PortfolioPosition 之和闭合到 ExchangePosition，各投资组合占用不超过自身 PortfolioBalance，账户总占用不超过可用 ExchangeBalance。

### PortfolioReduceOnly 与 VenueReduceOnly

- PortfolioReduceOnly 保证成交后不增加目标 VirtualPortfolio 的绝对 PortfolioPosition，也不反向开仓。
- VenueReduceOnly 保证成交后不增加净 ExchangePosition 的绝对值，由 Venue 标志强制。
- StrategyInstance 和 DeRisk 表达 PortfolioReduceOnly，不能自行决定最终 Venue 标志。
- 执行网关同时模拟组合仓位和真实净仓位：两层都减小时可以发送 VenueReduceOnly；组合减仓但 Venue 净仓位增加时发送普通订单，同时继续强制 PortfolioReduceOnly、GrossPortfolioMargin 和退出场景检查。
- PortfolioReduceOnly 订单的原 PortfolioMarginReservation 在成交及对账完成前不得释放。
- 虚拟减仓会造成真实账户保证金不足时禁止发送，触发 ExchangeAccount 范围 KillSwitch 并要求协调 DeRisk；不能用错误的 VenueReduceOnly 标志掩盖风险。
- OrderCommand 和恢复事实必须同时记录两种 reduce-only 判定。

### 强平、ADL 与其他强制成交

- VenueForcedExecution 表示 Venue 强平、ADL 或其他没有本系统 Order 的强制成交事实；不得伪造 OrderIntent、OrderCommand 或 Order 来套用 Fill。
- VenueForcedExecution 直接更新 ExchangePosition 和 ExchangeAccount 账务。
- ForcedExecutionAllocation 只分配给强制执行前与 ExchangePosition 同方向、对真实净仓位有贡献的 VirtualPortfolio，按其同方向绝对数量比例分配，并使用确定性的最大余数法处理最小数量单位。
- 反方向 PortfolioPosition 不直接分到本次强制减仓。
- 强制成交数量、价格、RealizedPnL、费用和罚金的分配总和必须精确闭合到 VenueForcedExecution。
- 无法从强制执行前权威状态唯一归属时不得猜测；未归属部分进入 SuspenseAccount 并形成 ReconciliationBreak。
- 没有成交语义的保险基金、分摊或余额调整继续使用 VenueAdjustment。
- 任何 VenueForcedExecution 都锁存 ExchangeAccount 范围 KillSwitch；完成订单、仓位、余额、保证金和账务对账后仍须由 SystemOwner 重新 EnableTrading。

### 组合保证金与跨币种抵押品边界

- 首版唯一 MarginModel 是 IsolatedLinearUsdtV1：结算资产和合格抵押品都只有 USDT，每个 Instrument 独立逐仓，不使用 BTC、ETH、USDC 等现货余额，也不做跨 Instrument、跨 VirtualPortfolio 或跨币种风险抵消。
- MarginRules、快照、订单准入、账务和风险事件都记录 MarginModel、结算资产及规则版本；历史状态永远按当时模型解释。
- 适配器收到组合保证金、跨仓、统一账户或多币种抵押品字段时标记 Unsupported，并禁止该 ExchangeAccount 通过首版生产准入。
- 未来 CrossMargin、PortfolioMargin 或 MultiCollateral 作为新的 MarginModel，只复用计算初始保证金、维持保证金、MarginBuffer 和 liquidation threshold 的小接口。
- 新模型必须另行定义抵押品资格、haircut、ValuationRoute、集中度、相关性、跨组合收益分配和压力测试；AccountNettingBenefit 不能充当抵押品。
- 首次启用新 MarginModel 使用独立 ExchangeAccount 或子账户并执行干净切换，要求零仓位、零挂单及完整 OpeningBalance；不迁移存量逐仓仓位。
- 首版不建设保证金 DSL、动态规则插件系统或通用组合风险引擎。

### MarginRules 来源与切换

- MarginRules 只能来自适配器验证过的 Venue 元数据/API 和版本化人工配置，禁止运行时抓取网页、根据拒单反推规则或使用未记录默认值。
- 每个版本记录来源时间、适用账户模式、完整风险档位、费率、扣减额、费用、舍入及测试向量。
- MarginRules 通过 ConfigEvent 在明确 shard sequence 屏障原子生效；同一事件的订单准入、PortfolioMarginBuffer 和 ExchangeMarginBuffer 使用同一版本。
- 新规则生效时重算全部持仓、挂单、PortfolioMarginReservation 和 LiquidationDistance。
- 要求收紧时先禁止新增风险并取消无法重新取得资格的增仓挂单；不足持仓触发 KillSwitch，等待人工 DeRisk。
- 要求放宽时只有已验证 ConfigEvent 生效后才释放占用，不根据单次 Venue 响应自动增加购买力。
- 每次仓位、标记价格或规则变化都重新确定风险档位，不能只在开仓时固定。
- MarginRules 缺失、过期、来源冲突或无法覆盖当前名义价值时，相关 Instrument 风险状态为 Unknown 并禁止新增风险。
- 旧规则和测试向量随决策日志及快照保留；回测、恢复和审计使用当时版本。
- Venue 不提供完整规则字段时，适配器用官方示例及测试环境结果固定配置并通过差分测试；无法验证则 Instrument 不进入生产。

### 保证金对账

- 私有 WebSocket 用于及时更新；REST 快照用于启动、断线恢复和权威对账。
- 启动、私有流重连、MarginAdjustment、MarginRules 切换和 VenueForcedExecution 后执行完整对账；正常运行按 Venue 限流允许的固定周期复核。
- 每个 ExchangeAccount + Instrument 核对账户和逐仓模式、自动追加保证金关闭、Venue 杠杆、MarginRules、ExchangePosition 与 PortfolioPosition 之和、ExchangeMarginBucket、VenueNetMargin、ExchangeMarginBuffer、风险档位、维持保证金和强平价格。
- 同时核对 ExchangeBalance 与 PortfolioBalance、TreasuryPortfolio、SuspenseAccount 的闭合，以及 GrossPortfolioMargin、AccountNettingBenefit 和全部未完成订单占用。
- 只允许 MarginRules 明确定义的最小单位舍入容差，禁止宽泛百分比容差。
- 模式、杠杆、自动追加状态、仓位或保证金不一致形成 MarginReconciliationBreak，并立即锁存对应 ExchangeAccount 新增风险权限。
- 对账差异不能通过覆盖本地状态消除；Venue 新事实追加到日志，归属不明部分进入 SuspenseAccount。
- 差异解决后最多进入 Ready，必须由 SystemOwner 重新 EnableTrading。

### 回测与仿真保真度

- 回测、仿真和实盘调用同一套定点 MarginModel、MarginRules、挂单最坏场景、双层 MarginBuffer 和 LiquidationDistance 计算。
- 历史运行使用当时可见的标记价格、MarginRules 和规则生效时间；历史风险档位或规则版本缺失时 DatasetQuality 为 Degraded，不能用于生产资格。
- SimulatedVenue 维护净 ExchangePosition 和 ExchangeMarginBucket；VirtualPortfolio 仍按毛额占用，AccountNettingBenefit 仍不可消费。
- 模拟 ExchangeMarginBuffer 穿越零时产生 VenueForcedExecution，而不是普通 Fill，并使用明确的保守成交价格、强平费用和延迟模型。
- Venue 未公开强平队列、保险基金或 ADL 细节时明确记录近似假设，不能声称精确复现。
- 普通策略资格运行发生 VenueForcedExecution 即判失败；专门压力和故障场景可以允许它，用于验证分配、账务和恢复。
- 回放复现 MarginRules ConfigEvent、MarginAdjustment、FundingSettlement 和 VenueForcedExecution 的原始顺序，并得到相同保证金状态及账务哈希。

### MarginSafetyGates

- OpeningGate 要求新订单最坏成交后的 PortfolioMarginBuffer、ExchangeMarginBuffer 和 LiquidationDistance 都高于开仓门槛，否则拒绝增加风险。
- WarningGate 跌破时告警并禁止继续扩大该方向风险，但不自动撤销全部订单或减仓。
- KillGate 跌破、健康度 Unknown 或规则/对账失效时触发对应范围 KillSwitch，撤销挂单并只允许 PortfolioReduceOnly。
- 每档门槛同时包含结算资产绝对金额、相对持仓名义价值的基点和最低 LiquidationDistance，实际采用最严格结果。
- VirtualPortfolio 与 ExchangeAccount 分别配置并取更严格层；StrategyLimit 不能放宽 AccountSafetyCeiling。
- 门槛通过 ConfigEvent 版本化发布并参与回放。首版不硬编码通用数值，由 Venue 测试、策略波动和压力回测资格化。
- 自动动作止于 KillSwitch；WarningGate 和 KillGate 都不自动 MarginAdjustment、DeRisk 或 Flatten。

### 首版验收

- 四个 Venue 分别以官方示例、风险档位边界和测试环境结果验证 MarginRules；本地初始与维持保证金不得低估 Venue。
- 覆盖多空仓位、反向成交、档位跨越、极端价格、最小 tick、最大名义价值及全部保守舍入，证明权威路径不使用 f64。
- 验证买卖挂单最坏顺序、Market 保护价格、费用占用及 Reduce-only 不增加 PortfolioPosition。
- 构造多个 VirtualPortfolio 同向、反向和完全抵消场景，验证 AccountNettingBenefit 不增加购买力，任一策略退出仍有保证金支持。
- 验证 PortfolioReduceOnly 但非 VenueReduceOnly 的减仓，不会错误设置 Venue 标志或提前释放 PortfolioMarginReservation。
- 验证 MarginAdjustment 的增加、释放、资金来源及 Venue 自动追加保证金关闭。
- 在 MarginRules 收紧、放宽和风险档位变化时验证原子重算、撤单和 TradingAuthorization 处理。
- 对标记价格、规则、仓位、余额、ExchangeMarginBucket 和强平价格注入缺失或差异，验证 Unknown、MarginReconciliationBreak 和 KillSwitch。
- 注入强平、ADL 和非成交调整，验证 VenueForcedExecution、ForcedExecutionAllocation、VenueAdjustment、SuspenseAccount 及账务闭合。
- 回放同一事件流必须得到相同 MarginBuffer、LiquidationDistance、订单准入、强制执行分配和账务哈希。
- 正式性能资格负载中开启完整保证金检查，并继续满足 InternalOrderLatency；关闭保证金逻辑的结果不能用于资格。

四家 Venue 当前风险档位、接口字段和测试向量由后续研究票维护，不把易变化外部规则硬编码进本架构决策。
