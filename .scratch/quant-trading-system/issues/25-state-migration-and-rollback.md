# 定义策略状态迁移与回滚契约

Type: grilling
Status: resolved
Blocked by: 13, 24
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

TradingShard 和策略版本变化时，哪些状态必须兼容迁移、如何验证迁移结果、何时必须撤单，以及新版本产生交易后允许怎样回滚？

## Answer

### 状态分类与所有权

- **权威交易状态（AuthoritativeTradingState）**：订单、成交、持仓、账本、风险占用、配置版本及分片游标。它由权威事实、快照和日志恢复，不由策略迁移。
- **策略私有状态（StrategyPrivateState）**：指标窗口、模型状态等策略连续决策所需状态。它使用显式版本化状态结构，并且只有这一类状态允许执行状态迁移。
- **可重建状态（RebuildableState）**：行情簿、指标缓存等可由权威输入重放、重新同步或预热得到的状态。它优先重建，不逐字段迁移。
- **临时运行状态（EphemeralRuntimeState）**：线程、指针、分配器内部状态、队列、连接及 Python 解释器对象等。它一律不迁移。
- VirtualPortfolio 及订单、成交、持仓和账务等经济事实独立于策略代码版本；代码升级或回滚不得撤销、覆盖或倒退已经发生的经济事实。

### 状态版本兼容

- 每份快照或 StrategyCheckpoint 必须记录 StateSchemaVersion、生成它的 ReleaseArtifact 或 StrategyDefinition 版本、参数版本及对应分片序号。
- StateSchemaVersion 完全一致时可以直接读取；版本不一致时，只有存在明确的“源版本到目标版本”StateMigration 才允许升级。
- StateMigration 必须是确定性纯函数：相同输入得到相同输出，不访问网络、文件、时钟或随机数。
- 禁止尽力读取、字段猜测和隐式自动兼容；未知版本、由较新版本生成的状态或迁移失败都会阻止目标策略激活。
- 第一版只保证当前生产版本到候选版本的迁移，不预先建立任意历史版本之间的迁移矩阵。

### 迁移验证

迁移必须在候选状态尚未取得交易权限时完成以下验证：

1. **结构验证**：迁移结果能够由目标版本严格解码，并通过字段范围、集合唯一性和序号连续性等结构校验。
2. **经济不变量验证**：在同一分片屏障处，迁移前后的订单、成交、持仓、账本、风险占用及游标的 CanonicalStateDigest 必须完全一致。
3. **策略自定义不变量验证**：每种策略只提供其私有状态真正需要的断言，例如窗口长度、时间顺序、累计量守恒或模型维度；第一版不建立通用验证框架。

候选版本还须从同一屏障开始对同一段历史事件进行影子重放，证明不会崩溃、不会产生非确定性结果，也不会发出非法 OrderIntent。策略升级可能有意改变行为，因此不要求新旧版本的 OrderIntent 完全相同；差异必须能归因于本次代码或参数变化。

### 策略状态处理方式

每次策略代码或参数版本切换必须明确声明一种 StrategyStateTransition：

- **Keep**：状态结构和语义均未改变，可直接继续使用，例如不影响状态的代码修复。
- **Migrate**：状态含义不变，仅结构或表示方式改变，并提供明确的 StateMigration。
- **Rebuild**：指标定义、窗口语义、模型、交易标的集合或依赖参数已经改变；旧 StrategyPrivateState 被丢弃，并从分片决策日志重新预热。

Rebuild 未取得足够历史数据或未通过策略自定义不变量验证时，策略保持 WarmingUp：可以接收事件，但不得产生 OrderIntent。三种方式都不得改变或回退 AuthoritativeTradingState。

### 切换前撤单

所有代码或参数版本切换都必须先执行 CutoverDrain：

- TradingShard 核心代码切换时，撤销受影响 DecisionDomain 的全部未完成订单。
- 单个原生或 Python 策略代码切换时，只撤销该 StrategyInstance 拥有的全部未完成订单。
- 策略参数版本切换时，同样撤销该 StrategyInstance 的全部未完成订单；第一版不分析参数是否影响挂单。
- Keep、Migrate 和 Rebuild 均执行相同撤单规则，状态处理方式不能证明旧订单仍符合新版本意图。
- 系统必须收到撤单结果并完成 Venue 对账；存在 Unknown 订单时，目标版本不得增加风险，只允许继续撤单、对账或 Reduce-only。

### 新版本交易后的回滚

回滚采用 ForwardRollback，代码可以恢复为旧版本，但经济状态和系统进度只能继续向前：

- 禁止恢复切换前的订单、持仓、账本、分片游标或旧快照；已经发生的订单、成交、费用和账务事实永久保留。
- 回滚是一次新的正向切换：在当前分片屏障暂停受影响策略，完成 CutoverDrain，再把旧代码作为候选版本重新激活。
- 旧代码从当前 AuthoritativeTradingState 继续运行；StrategyPrivateState 优先取自持续重放的旧版影子实例，否则采用 Rebuild 从日志重新预热。
- 第一版不要求反向 StateMigration。若旧代码既无法处理当前事实，也无法重建合格状态，则回滚失败，策略保持停止，不得强行加载旧状态。
- 回滚后的发布代次必须继续递增；ReleaseArtifact 的代码内容可以变旧，但激活记录和系统状态版本不得倒退。

### 原子切换

所有版本切换以 CutoverBarrier 原子完成：

1. 候选版本先完成加载、Migrate 或 Rebuild，以及影子验证。
2. 在分片序号屏障把受影响范围置为 Quiescing，停止产生新的 OrderIntent。
3. 完成 CutoverDrain；撤单和对账事件仍由当前权威核心处理。
4. 在新的稳定屏障产生当前状态，候选版本追平到该屏障并再次验证。
5. 一次性替换活动代码版本、参数版本和策略状态引用。

同一个输入事件不得由两个活动版本处理，也不得出现代码版本与状态版本混搭。切换前失败时丢弃候选状态，旧版本可从当前屏障恢复；切换后失败不得暗中切回，必须执行 ForwardRollback。

单策略更新的原子范围是该 StrategyInstance；TradingShard 核心更新的原子范围是整个受影响 DecisionDomain。

### Python 策略

Python 策略遵守与原生策略相同的 StateSchemaVersion、StrategyStateTransition、三层迁移验证、CutoverDrain 和 CutoverBarrier：

- Python checkpoint 只能包含由显式 schema 定义并可稳定编码的基础数据；禁止以 pickle、marshal、解释器对象或任意对象图作为权威状态格式。
- Python StateMigration 只能在无交易权限的候选 Strategy Host 中执行；异常、超时或非法输出均视为迁移失败。
- Strategy Host 只能提交迁移后的 StrategyPrivateState，不能修改订单、持仓、账本或其他 AuthoritativeTradingState。
- 第一版不为 Python 建立独立迁移框架；原生与 Python 策略共用协议、状态分类和验证结论。

### 策略实例身份

- 策略代码发生变化时创建新的 StrategyInstance；旧实例永久失去交易权限，新实例作为 StrategySuccessor 接替同一 VirtualPortfolio。
- ForwardRollback 同样创建新的 StrategyInstance，不复活历史实例。
- 仅参数版本发生变化时保留当前 StrategyInstance，参数版本和策略决策序号继续递增。
- 仅 TradingShard 基础设施代码变化且 StrategyDefinition 内容哈希未变时，保留对应 StrategyInstance。
- StrategyPrivateState 可以按 Keep、Migrate 或 Rebuild 转交给 StrategySuccessor；订单、成交、持仓和账本始终通过 VirtualPortfolio 延续。
- 新 StrategyInstance 拥有新的 OrderIntent 身份空间，其策略决策序号可以从头开始，不会与旧实例的客户端订单身份冲突。

### 可重放的激活事实

- 每次 CutoverBarrier 产生一条不可变 VersionActivationEvent，记录旧/新 StrategyInstance、StrategyDefinition 与参数版本、StrategyStateTransition、StateSchemaVersion、CanonicalStateDigest 和分片序号。
- VersionActivationEvent 必须在新版本获得新增风险权限前完成本地持久化并由热备确认；它属于低频控制路径，不改变订单热路径不做同步刷盘的决定。
- 事件之前只有旧版本是权威版本，事件之后只有新版本是权威版本；候选中间状态永远不参与恢复。
- 回放以最后一条有效 VersionActivationEvent 决定活动版本。
- 若故障导致激活事实、ReleaseArtifact 或 Venue 事实互相矛盾，恢复实例进入 RecoveryOnly；完成对账前不得猜测活动版本或增加风险。

### 首版验收

首版使用以下最小验收矩阵：

- **Keep**：相同 schema 可直接恢复，CanonicalStateDigest 不变。
- **Migrate**：受支持版本迁移成功；相同输入重复执行产生完全相同结果。
- **非法迁移**：未知版本、较新版本、损坏数据和不变量失败均拒绝激活。
- **Rebuild**：历史不足时保持 WarmingUp，补足历史并通过验证后才能产生 OrderIntent。
- **切换故障**：分别在 Quiescing、撤单、对账、迁移和 VersionActivationEvent 写入阶段注入崩溃；恢复后只能明确得到旧版本、新版本或 RecoveryOnly，不能双活。
- **成交后回滚**：新版本产生真实成交后执行 ForwardRollback，验证成交、持仓、账本和风险占用没有倒退或重复。
- **Python**：拒绝非稳定 schema 数据、pickle、marshal 和解释器对象。
- **范围隔离**：单策略升级不得暂停同一分片内无关策略；TradingShard 核心升级才暂停整个受影响 DecisionDomain。

迁移不位于订单热路径，因此首版不为迁移耗时设独立 SLA；QualificationReport 记录迁移耗时和状态大小，只有实测影响发布窗口时才增加明确门槛。
