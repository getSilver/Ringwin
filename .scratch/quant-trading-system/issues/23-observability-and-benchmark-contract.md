# 定义可观测性与性能验收契约

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

系统必须暴露哪些延迟、吞吐、队列水位、时钟质量、账本差异和恢复指标，基准工作负载、测量点、预热规则及验收失败条件是什么？

## Answer

### Authoritative latency measurement points

- `CoreDecisionLatency` 从 TradingShard 取得一个已标准化事件开始，到产生该事件最后一个相关 `OrderIntent` 为止；所有普通行情事件都进入核心处理分布，包括未产生意图的事件。权威门槛为正常负载 P99 不超过 10 μs。
- `InternalOrderLatency` 从适配器收到 `recv` 完成、数据可供用户态读取开始，到一个通过风控的订单报文完成序列化并可提交发送为止。它覆盖解析、订单簿、跨线程排队、策略、本地风控、OMS 及报文编码，权威门槛为正常负载 P99 不超过 50 μs。
- 实际产生并通过风控的订单路径进入 `InternalOrderLatency`；拒绝路径单独形成分布，不能混入成功订单分布。没有产生订单的行情仍进入 `CoreDecisionLatency`。
- NIC RX/TX 硬件时间戳形成独立的 `HardwarePathLatency`，用于观察内核、驱动和网卡路径。它不能在硬件不支持时与用户态测量混合，也不能替代内部端到端合同。
- 解析、订单簿、队列等待、策略、风控、OMS、序列化等阶段延迟必须分别可诊断，但不是拆分后的独立通关捷径。任何权威端到端指标失败即整体失败，即使全部阶段指标单独看似达标。

### Latency distribution integrity

- `CoreDecisionLatency`、`InternalOrderLatency` 及其他资格分布必须对全部相关事件计数；每个 TradingShard 使用固定容量、本地写入的直方图，热路径不得因观测发生动态分配、阻塞锁或跨核共享写入。
- 跨分片结果先合并 bucket 计数再计算分位数，禁止对各分片 P99 或其他分位数做算术平均。
- 每个分布固定报告样本数、P50、P90、P99、P99.9、最大值和直方图溢出数。出现 bucket 溢出说明测量配置无效，不得把溢出样本截断为最高 bucket 后继续验收。
- 负载生成器按独立计划时间发出事件，并同时记录计划与实际发出时间；生产者落后、暂停和排队必须进入观察结果，禁止 coordinated omission。
- 权威验收窗口的每个相关分布至少包含 1,000,000 个样本。订单路径样本不足时，使用确定性基准策略提高下单比例，不能以少量自然订单估算 P99/P99.9。
- 全量固定直方图用于资格判断；高基数详细 trace 只允许有界抽样并用于诊断，不能代替权威分布。

### Mandatory load scenarios

生产资格运行必须全部通过以下场景，且始终开启正式日志、指标、本地风控、OMS、L2 订单簿及约 100 个策略；关闭功能得到的裸核心数字只可用于诊断。

1. `SteadyBalanced`：聚合 2,000,000 个标准化事件/秒，四个 TradingShard 近似均匀，连续运行 30 分钟。
2. `SteadyHotShard`：聚合仍为 2,000,000 events/s，但 50% 事件进入一个 TradingShard，连续运行 30 分钟。
3. `BurstRecovery`：先以 2,000,000 events/s 稳定运行 5 分钟，再提升到 5,000,000 events/s 持续 10 秒，随后回到持续负载并运行到全部有界队列恢复正常水位；每轮资格验收重复 10 次。
4. `RecordedPeakReplay`：分别回放 OKX、Binance、Gate.io 和 Bitget 的至少一个已知真实高峰窗口，保留原始消息尺寸、交易所批次、Instrument 倾斜及实际跨连接到达顺序。

合成负载用于跨版本可重复比较，真实高峰回放用于发现合成模型遗漏；二者不能互相替代。任何单一强制场景失败即本次资格运行失败。

### Canonical synthetic workload

- 固定使用 128 个 Instrument，覆盖四个 Venue 和四个 TradingShard；现货与 USDT 永续各占一半。
- 标准化输入事件比例为 75% L2 增量、10% MarketTrade、5% 标记价格/指数价格/资金费率、5% TimerEvent，以及 5% 订单回报/成交/余额/仓位/配置事件。
- L2 增量必须包含单价位、小批量多价位和大批量更新，不能只使用开销最低的单价位消息。
- 四个原生确定性基准策略分别绑定一个 TradingShard，检查全部输入，并合计产生至少 1,000 条成功订单路径/秒，使 30 分钟窗口至少获得 1,800,000 个 `InternalOrderLatency` 样本。
- 订单动作固定为 60% 新限价单、30% 撤单、10% 改单。不支持原生改单的 Venue 按能力契约执行撤单加重下，并单独形成分布，不能混入原生改单结果。
- 同时运行四个 Python Strategy Host、共 100 个中低频策略；每个 Host 的输入基线为 1,000 batches/s。Python 延迟单独报告，不纳入 10 μs 原生核心合同。
- 每次资格运行以不可变 `BenchmarkManifest` 标识负载场景、数据集或生成规则、随机种子、InstrumentRules、策略构建、软件构建、节点基线、运行配置和观测开关。身份不同的运行不能默认直接比较。

### Mandatory runtime signals

系统必须持续暴露以下六组信号：

1. 性能与容量：权威及阶段延迟分布，各阶段 events/s、orders/s、bytes/s，以及每核 cycles/event。
2. 有界队列：当前占用、容量、最高水位、最老事件年龄、入队失败、合并、丢弃、缺口次数和恢复后的排空时间。
3. 交易正确性：OrderState 数量、`Unknown` 数量及最老年龄、重复/乱序 ExecutionReport、风险拒绝、RiskLease 剩余额度、订单簿健康状态、capture gap 和日志序号缺口。
4. 账务与对账：未解决 ReconciliationBreak 的数量和最老年龄、按 Asset 的差异绝对值、双层账本闭合失败、SuspenseAccount 未归属余额和估值缺失数量。
5. 时间质量：PTP/PHC 锁定状态、时钟偏移、最大误差界限、硬件时间戳可用性、单调时钟异常，以及各来源 source_time 与 receive_time 的偏差分布。
6. 恢复与系统资源：主备重放、日志持久化和 StrategyCursor 的游标差，恢复状态及耗时；CPU 使用率、迁核、上下文切换、page fault、NUMA 远端访问、IRQ、io_uring 队列深度、磁盘吞吐和同步延迟。

热路径只写固定内存且由本地单写者拥有的计数器或直方图，异步外围负责合并和导出。常驻指标标签只允许 Venue、TradingShard、事件类型、健康状态等有界集合；Order、Instrument、StrategyInstance、client_order_id 等高基数身份不能成为常驻标签，定位时使用日志或有界 trace。

观测模块必须观测自身的丢样、直方图溢出、导出失败、聚合延迟及最后成功导出时间。观测数据缺失不能被解释为系统健康。

### Warm-up and repetition

- 每次资格运行必须先满足正确性启动条件：所需订单簿处于允许状态、账户对账完成、RiskLease 有效、日志及观测模块健康；否则不得开始计时。
- 随后至少预热 10 分钟。只有 CPU 温度与频率、队列水位、吞吐和 P99 在连续 2 分钟内没有明显趋势，才能开启正式窗口。
- 最长预热为 30 分钟；仍不能稳定即本次运行失败，禁止无限等待偶然的良好窗口。
- 正式窗口开始时清零资格直方图和计数器，但不重启进程，也不清空订单簿、策略状态、文件缓存或 allocator 状态。
- 每个强制场景必须连续取得 3 次有效通过。任一次失败即该组失败；调查并修正后须重新执行完整三次，禁止从更多运行中挑选最好的三次。
- 报告保留每一次结果及三次合并分布，不只报告平均值；每一次必须单独满足全部门槛。
- 冷启动、无页面缓存及故障恢复性能属于独立恢复场景，不能与稳定态资格窗口混合。
- 无关进程必须停止；CPU 频率策略、IRQ、CPU/NUMA 亲和、内核、固件、温度范围及电源策略均写入 BenchmarkManifest。

### Hard failure conditions

任一条件出现即整轮失败，不能由其他指标平均抵消：

- `CoreDecisionLatency` 必须满足 P99 ≤ 10 μs、P99.9 ≤ 20 μs、max ≤ 1 ms；`InternalOrderLatency` 必须满足 P99 ≤ 50 μs、P99.9 ≤ 100 μs、max ≤ 5 ms。
- 出现任何关键事件丢失或重复生效、无法解释的序号缺口、Order 身份冲突、账本不闭合、确定性重放结果不一致、新增 ReconciliationBreak、无法解释的 Unknown Order 或 SuspenseAccount 增量。
- 强制容量场景出现 L2 gap 即失败；成功检测和重同步只证明安全降级，不能证明容量达标。
- 任一关键通道入队失败或达到满容量；稳定负载下队列持续增长；BurstRecovery 回到 2 M events/s 后 60 秒仍未恢复到突发前水位范围；日志、热备或 StrategyCursor 差持续扩大。
- PTP/PHC 失锁、绝对偏移超过 1 μs、硬件时间戳中断或单调时钟倒退。
- TradingShard 发生 CPU migration、测量窗口出现 major page fault或热路径动态分配，或者节点发生 thermal throttling。
- 负载生成器无法按计划供给、样本不足、直方图溢出、权威指标丢样、观测停止导出，或者 BenchmarkManifest 与实际环境不一致。这些情况作为运行无效并失败，不能解释为达标。
- OOM、进程异常退出、io_uring CQ/SQ 溢出、磁盘错误、日志 segment 无法提交或任何失败关闭状态被触发。

### Telemetry publication failure

这里的“发布”只指 `TelemetryPublish`：把本地聚合的延迟分布、吞吐、队列、时间质量、账务差异汇总和健康状态异步发送到监控存储、仪表盘或告警通道。它不包含原始接入日志、分片决策日志、完整订单/成交/账本、ResearchDataset 或 SecretMaterial；这些权威资料使用各自既定管道。

- 队列满、行情 Gap、日志失败和账本异常等安全条件由交易面本地检测并直接执行失败关闭，不依赖外部监控抓取。
- 遥测聚合与发布位于异步外围；变慢或失败不得阻塞 TradingShard，也不得反向占满交易通道。
- 连续 30 秒没有成功发布时，节点进入 `ObservabilityDegraded` 并通知 SystemOwner；核心仍按本地安全规则运行。
- 连续 5 分钟仍未恢复时禁止新增风险，只允许撤单、减仓和对账，不自动强制平仓。
- 发布恢复后不能自动解除新增风险禁令；必须确认缺失期间权威交易日志完整且关键健康状态正常。
- 本地遥测缓冲必须有界；容量耗尽时先丢弃诊断明细和 trace，保留累计计数及当前健康状态，不能占用交易事件内存。
- 观测外围可独立重启，不要求重启 TradingShard。

### Python strategy latency

- 首版只定义一个 `PythonDecisionLatency` 等级：从 TradingShard 将事件批次发布到共享内存开始，到该批次产生的 `OrderIntent` 返回 TradingShard 并完成基础身份、新鲜度及 schema 验证为止。
- 该时间只覆盖本机 IPC、进程调度、批处理等待、Python 执行/GC、返回队列及本地验证；不包含行情到节点的公网延迟、后续风控/OMS/订单编码、订单发送到 Venue、撮合或回报网络延迟。
- `PythonDecisionLatency` 必须满足 P99 ≤ 50 ms、P99.9 ≤ 100 ms。
- Strategy Host 从共享内存取出批次准备调用策略时，若批次自 TradingShard 发布以来已超过 50 ms，则不得执行回调，直接进入 `NeedsSnapshot`。
- `OrderIntent` 返回时若对应批次年龄超过 100 ms，TradingShard 必须将其作为 stale intent 拒绝，不进入风控或 OMS。
- Python 分布独立报告，不进入 `CoreDecisionLatency` 或 `InternalOrderLatency`。一个 Host 落后不得影响其他 Host 或 TradingShard；未按期恢复、重复恢复或输出通道填满时，Python 资格场景失败。
- 首版不建立更多 Python 延迟等级；真实策略证明单一等级不足后再扩展。

### Regression gate

- 每个候选 ReleaseArtifact 同时接受绝对性能门槛和当前生产基线比较。
- 相对比较要求相同 BenchmarkManifest、节点、固件、内核和连续三次运行；条件不同只能并列展示，不能计算回归率。
- 即使绝对门槛仍通过，只要三次运行的合并结果出现任一变化，候选版本仍判为性能回归：`CoreDecisionLatency` 或 `InternalOrderLatency` 的 P99/P99.9 恶化超过 5%；cycles/event 增加超过 5%；同负载下任一关键队列最高水位增加超过 10 个百分点；BurstRecovery 排空时间增加超过 10%。
- 小于门槛的变化继续记录但不阻止发布，避免把正常测量噪声当作优化目标。
- 性能回归必须修复，或由 SystemOwner 在看到影响范围后显式接受；不能通过更换基线、删除场景或修改 BenchmarkManifest 隐藏。
- 候选 ReleaseArtifact 正式成为生产版本后，才成为新的比较基线。

### Qualification evidence

每次资格活动生成不可变 `QualificationReport`，至少包含：

- BenchmarkManifest、候选 ReleaseArtifact 内容哈希和生产基线身份。
- 三次有效运行以及本次活动的全部失败、无效运行，不得只保留通过结果。
- 每个权威分布的原始 bucket 计数、样本数、溢出数、P50/P90/P99/P99.9/max。
- 吞吐、队列最高水位和时间序列、突发排空过程、时钟质量及全部硬失败检查结果。
- CPU/NUMA/IRQ、内核、固件、温度与频率、磁盘及 io_uring 状态。
- 负载生成器计划与实际发出情况，以检查 coordinated omission。
- 与生产基线的逐项差异及最终 `Passed`、`Failed` 或 `Invalid` 结论；`Invalid` 不能视为通过。
- SystemOwner 对性能回归的显式接受记录（如果存在）。

报告及其原始测量文件使用内容哈希保持不可变，并由 RetentionPolicy 管理；当前生产版本、候选版本或事故调查仍引用时不得回收，不额外规定固定保存年限。

### Observability overhead budget

- 正式资格运行始终开启全部强制指标，并以开启后的结果判断 10 μs/50 μs 合同。
- 使用相同 BenchmarkManifest 另做一次诊断性 A/B，仅关闭指标计数、直方图和 trace；权威日志、风控及其他生产功能仍保持开启。
- 开启观测相对关闭观测不得使 cycles/event 增加超过 5%、`CoreDecisionLatency` P99 增加超过 1 μs、`InternalOrderLatency` P99 增加超过 2 μs，或持续吞吐能力下降超过 5%。
- 超过任一预算即观测实现失败，不能通过关闭生产指标解决。
- TelemetryPublish 进程的 CPU 与内存预算留给生产进程拓扑决策；本票只约束交易热路径的观测成本。
- 抽样 trace 默认关闭；事故诊断时开启仍必须使用固定采样率和有界内存，禁止无限收集。
