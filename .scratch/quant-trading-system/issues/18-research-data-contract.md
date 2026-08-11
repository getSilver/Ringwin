# 定义研究数据保留与查询契约

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

原始行情、标准化事件、订单簿快照、订单及成交数据需要保留多久，以什么时间粒度和并发规模支持研究、回测、审计与重算？

## Answer

规范研究数据词汇记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### Data classes and authority

- SourceArchive 由交易面异步封存的原始接入日志和分片决策日志组成，包括原始行情、账户与订单回报、标准化输入、配置、策略意图、风控结果、订单及成交事实；它不可变，是重新解析、审计和确定性重放的最终来源。
- ReplayDataset 从 SourceArchive 按 Venue、Instrument、时间范围及事件类别构建，具有不可变 DatasetManifest、完整性清单和内容哈希，供 L2ReplayBacktest 使用。
- ResearchDataset 包括 K 线、BBO、BookCheckpoint、因子、标签及统计表等可重建派生数据；必须记录生成规则及上游身份，允许按 RetentionPolicy 淘汰。
- RunArtifact 保存一次研究、回测或仿真的 RunManifest、决策事实、模拟 Fill、账本、资格检查及报告。
- BookCheckpoint 只用于缩短 L2 seek；Snapshot + Delta 事件仍是权威订单簿来源。
- 研究查询不得读取交易面正在写入的日志，只能读取异步发布到研究数据面的已封存分段。

### Retention

- 公共原始行情 SourceArchive：最近 30 天为热层，最近 1 年为温层，冷层保留 5 年。
- 私有订单、成交、账户、账本和分片决策日志：最近 90 天为热层，冷层至少保留 7 年；适用法律、税务或审计要求更长时取更长期限。
- 被生产策略、ComparableRun、CalibrationProfile 或已发布报告引用的 ReplayDataset 必须固定保留；未被引用的临时版本可在 180 天后回收。
- ResearchDataset 默认作为可重建缓存，90 天未访问且无固定引用时可以回收；研究基准随对应报告保留。
- 生产资格、上线版本及实盘事故相关 RunArtifact 保留 7 年；普通研究运行保留 1 年；失败且未引用的参数搜索中间产物保留 30 天。
- DatasetManifest、内容哈希、血缘和删除记录永久保留。任何被保留对象引用的数据不得删除。

### Time granularity

- SourceArchive 与 ReplayDataset 永久保留事件级精度、原始 source_seq、ReplayOrder 及全部已记录时间戳，不为压缩截断时间精度。
- 所有时间查询和分区使用 UTC 半开区间 `[start,end)`。
- L2 以 Snapshot + Delta 为权威，另在每 60 秒及每次 Gap 恢复后生成完整 BookCheckpoint。
- MarketTrade、Order、Fill、LedgerTransaction 及配置事实保持逐事件粒度。
- 首版物化 1 秒和 1 分钟标准研究序列；5 分钟、1 小时及日线等从 1 分钟数据确定性聚合，亚秒研究按需从事件流生成。
- TimeBucket 按 UTC epoch 对齐；空桶明确记录缺失和健康状态，禁止静默前向填充。
- 聚合记录保留上游版本、时间区间、生成规则及质量标记。

### Capacity contract

- 元数据与血缘查询支持 16 个并发请求，热数据 P95 不超过 200 ms。
- 交互分析支持 4 个并发研究会话；单 Instrument 一天的 1 秒序列或一年 1 分钟序列，热数据 P95 不超过 2 秒。
- L2ReplayBacktest 支持 8 条并发顺序流，本地热缓存下每条持续提供至少 2M events/s，合计目标 16M events/s。
- 批量 ResearchBacktest 与参数搜索允许最多 32 个并发 worker；它们有界排队、优先级低于交互查询和生产资格回放，不承诺交互延迟。
- 冷层首次取回不适用热层延迟目标。研究与回测不得在生产交易节点执行，也不能侵占四个交易核心。

### Dataset interface

- 研究代码只持有 DatasetRef，不依赖物理文件路径、表名或存储引擎。
- DatasetRef 指向已发布、不可变的 DatasetManifest；同一查询期间保持快照一致。
- 数据模块只暴露两种读取语义：`scan` 按 Venue、Instrument、UTC 时间、字段及谓词读取列式研究数据；`replay` 按 ReplayOrder 流式读取生产核心可消费事件。
- 目录可按数据类别、覆盖时间、DatasetQuality 和血缘发现 DatasetRef；“latest”只能在任务开始时解析一次并固定进 RunManifest。
- 普通 scan 不承诺隐式行序；replay 明确保证 ReplayOrder。
- 研究任务不能原地修改数据集；清洗、补全、特征生成和重分区均发布新的 ResearchDataset。
- 字段裁剪、谓词下推和分区跳过隐藏在数据模块内部。首版不建设通用 SQL 网关或自研分布式查询层。

### Partitioning

- 逻辑分区按数据类别、权限域、Venue、产品类型、Instrument 和 UTC 时间组织。
- 原始 L2、MarketTrade 等高流量事件按小时分区；1 秒与 1 分钟研究序列按日分区。
- 私有订单、成交、账户及账本先按 ExchangeAccount 权限域隔离，再按日期分区；市场数据不按 StrategyInstance 或 VirtualPortfolio 复制。
- ReplayDataset 的 DatasetPartition 内保持 ReplayOrder，并记录首尾序号、时间范围及内容校验。
- SourceArchive 保留交易面原始分段；研究数据面可确定性合并小分段，但不能改变事件内容或次序。
- 发布文件压缩后目标为 256 MiB–1 GiB；单小时超限时按稳定序号范围继续切分，禁止随机切分。

### Atomic publication and correction

- 新 DatasetPartition 先写入不可见暂存区，完成结构、校验和、序号/时间范围、重复、缺口及引用完整性检查。
- 全部分区和 DatasetManifest 验证成功后，通过一次原子目录发布使 DatasetRef 可见；读者只能看到完整旧版本或完整新版本。
- 已发布分区不可追加、覆盖或删除其中记录。
- 迟到事件、重新解析、去重修复及更正生成新的数据集版本，并在血缘中引用被替代版本和修复原因。
- 稳定 DatasetRef 永远指向原版本；可变推荐指针只用于发现。
- DatasetQuality 使用 Pending、Complete、Degraded 或 Invalid，并记录具体缺口、重复、解析失败和时钟异常区间。
- SourceArchive 原始事实不修复；解析器错误只能通过新的解析版本纠正。

### Security

- 公共行情与私有账户数据使用不同权限域、加密密钥和物理分区，不得混入同一文件。
- API key、secret、签名原文、登录令牌及提现敏感信息不得进入 SourceArchive、ResearchDataset 或 RunArtifact。
- 私有原始回报保留审计所需内容；研究发布层默认以稳定内部标识替换交易所账户标识及客户端敏感字段。
- 数据权限至少按 ExchangeAccount 和 VirtualPortfolio 授予；研究任务只能生成权限交集内的派生数据。
- 普通研究默认使用脱敏订单、Fill 和账本视图；未脱敏原文访问属于受审计高权限操作。
- 私有数据读取、导出、权限变更和 RetentionPolicy 删除均记录不可变审计事件。
- 研究数据面不能反向修改交易账本、订单状态或 SourceArchive。
- 派生数据与 RunArtifact 继承全部上游中的最高 DataSensitivity。

### Durability

- 按用户明确选择，首版所有研究数据只使用 `1 副本 / 1 故障域`，不承诺灾难恢复 RPO 或 RTO。
- 单个磁盘、文件系统、存储账户或节点故障可能永久丢失 SourceArchive、审计历史及回测复现能力；这是已接受风险。
- 保留写入内容校验和与周期完整性扫描，但只能发现损坏，不能从副本修复。
- ResearchDataset 仅在其 SourceArchive 尚存时可以重建；数据丢失后，依赖对象必须标记为不可再现。
- 不要求跨故障域备份或季度完整恢复演练。
- 保留短期延迟删除以防普通误操作；它不解决整个存储域损坏。

### Point-in-time correctness

- 每个事实保留 source、receive、EffectiveTime 和 RecordedTime，不用单一时间戳覆盖。
- 回测使用当时可见视图；事实只在实际接收或记录后可见，迟到更正不能提前回填给历史策略。
- 审计和财务研究可使用按 EffectiveTime 重述的事后修订视图，但必须显式指定 KnowledgeCutoff。
- FeatureDataset 在特征时间只能读取 KnowledgeCutoff 之前已可见事实；跨数据集连接采用 as-of 语义。
- 未来收益、未来波动或事后分类等目标必须隔离在 LabelDataset，不能与策略输入字段混入同一默认 scan。
- ReplayDataset 默认提供生产当时可观察的事件顺序；修订视图形成新的 ResearchDataset。
- DatasetManifest 记录视图类型、KnowledgeCutoff、特征时间、标签窗口及生成版本。
- 发现未来数据泄漏后，相关数据集标记 Invalid，全部依赖 RunArtifact 失去资格。

### Deterministic lineage

- 每个已发布 ResearchDataset 具有 TransformationManifest，记录全部上游 DatasetRef、转换构建标识、参数、结构版本、比例尺、舍入及时区规则、运行环境、随机种子、输入输出范围、校验结果及生成身份。
- 相同输入与转换清单重跑必须生成相同内容哈希；否则数据集只能标记为实验性，不能作为 ComparableRun 输入。
- 血缘必须形成无环图，并可由 FeatureDataset、ReplayDataset 或 RunArtifact 追溯到 SourceArchive。
- Notebook 可用于探索，但不能直接发布基准数据集；发布必须由版本化、可重复执行的转换任务完成。
- 上游数据受 RetentionPolicy 保护期间，其全部转换清单同时保留。
- 验证失败的数据只能发布为 Invalid 供诊断，不能被默认发现接口选中。

### Freshness

- 交易面继续异步写日志；研究数据面只读取已封存并校验的分段。
- 已封存 SourceArchive 分段在关闭后 P95 60 秒内进入研究目录，单个分段最长开放 5 分钟。
- 标准 1 秒和 1 分钟 ResearchDataset 在源分段发布后 P95 15 分钟内生成。
- 每个 UTC 日结束后 1 小时内发布当日 DatasetQuality 报告。
- 未完成校验的数据只显示 Pending，不能作为 Complete 数据供默认查询。
- ShadowSimulation 直接使用生产实时事件流，不经研究存储。
- 实盘策略不得同步查询研究数据面；上线特征、参数或模型必须通过版本化发布进入交易面。

### Required query shapes

- 市场范围扫描：按 Venue、Instrument、事件类型及 UTC 时间读取行情、成交、标记价格和资金费。
- 订单审计定位：按 client_order_id、Venue order id、Order、Fill 或 correlation_id 定位，并沿引用读取 OrderIntent、OrderCommand、ExecutionReport 及 LedgerTransaction。
- 组合账务扫描：按 ExchangeAccount、VirtualPortfolio、Asset、Instrument、EffectiveTime、RecordedTime 及 KnowledgeCutoff 查询。
- L2 定位回放：找到起点前最近 BookCheckpoint，再按 ReplayOrder 应用后续 Delta。
- Point-in-time 状态重建：选择快照和后续决策日志，重建指定 shard_seq 的订单、仓位、余额及风险状态。
- 血缘查询：从 RunArtifact 或 ResearchDataset 反查 DatasetRef、TransformationManifest 和 SourceArchive。
- 质量查询：返回缺口、重复、时钟异常及不可用区间，不只返回布尔值。
- 普通 scan 必须提供时间范围或唯一标识；冷层查询显式提交取回任务。审计查询只返回事实与引用，不猜测关系。

### Numeric representation

- SourceArchive 和 ReplayDataset 中的 Price、Quantity、Money、Rate、序号及时间戳保留原始整数、比例尺和单位，不转成 f64 或格式化文本后再保存。
- Instrument、Asset、Venue、ExchangeAccount 和 VirtualPortfolio 使用稳定领域标识；交易所 symbol 仅作为附带字段。
- 零、缺失、不可用和未估值状态分别编码，不能统一表示为零、空字符串或 NaN。
- ResearchDataset 的统计量、因子及模型特征可以使用 f32/f64，但 DatasetManifest 必须记录类型、缺失语义及生成规则。
- 浮点 FeatureDataset 进入生产策略前必须经过明确验证、定点量化或模型构建发布，不能成为账本或订单权威值。
- OHLCV 的价格与数量优先保留定点整数；收益率、波动率等派生列才使用浮点。
- 查询引擎不得根据样本自动缩窄整数宽度或改变有符号性。

## Comments

- 2026-07-26：经逐项研究数据契约访谈确认并解决；完整建议保存在本 Answer，地图仅保存索引摘要。
