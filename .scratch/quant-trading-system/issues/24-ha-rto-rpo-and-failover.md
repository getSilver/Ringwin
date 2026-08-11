# 定义高可用 RTO、RPO 与故障切换政策

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

不同故障类型允许多长恢复时间和多少日志缺口，何时人工切换、何时允许自动切换，以及切换前必须完成哪些 fencing、对账和健康证明？

## Answer

### Failure classification

所有切换判断必须先归入一个 `FailoverCause`：

1. `PlannedSwitch`：版本发布、维护或主动迁移；旧主仍可信，可以在序号屏障有序交接。
2. `ProcessFailure`：单个 TradingShard、执行网关或相关进程退出，但节点仍可控制，旧进程的凭证和网络权限可以立即撤销。
3. `NodeFailure`：整机宕机、电源故障、内核崩溃或节点完全不可达；不能仅凭进程消失证明旧主永远不会恢复发单。
4. `NetworkPartition`：主节点、热备、控制面或 Venue 之间发生分区；优先防止旧主与热备形成双主。
5. `UntrustedState`：怀疑凭证泄露、节点入侵、日志/快照损坏、账本不闭合或 ReleaseArtifact 不可信；不得使用普通热备提升流程。

Venue API、市场数据或撮合自身中断属于对应 Venue 的外部安全降级，切换本地节点通常不能修复，不触发盲目主备提升。

### Two-layer RPO

- `EconomicRPO` 永远为零：任何已在 Venue 生效的订单、成交、费用、资金费、余额或仓位事实，以及已确认生效的 ControlCommand，最终都必须通过唯一身份、对账和幂等账务恢复，不能永久丢失或重复生效。它是语义承诺，不等于订单热路径同步刷盘。
- `ReplayRPO` 描述故障后可能无法逐事件重建的内部决策日志尾部。首版订单热路径不等待磁盘或热备确认，因此非计划整机故障允许有限非零尾部。
- PlannedSwitch 及节点仍可信的 ProcessFailure 必须实现 ReplayRPO 为零；无法补齐全部 shard sequence 时不得使用正常切换路径。
- NodeFailure 或 NetworkPartition 允许丢失尚未复制的内部决策尾部，但必须显式记录。已产生 Venue 外部效果的部分通过 client_order_id 和对账恢复；没有外部效果的未复制决策视为未发生，禁止猜测重建。
- ReplayRPO 缺口使策略私有状态失去证明时，相关 StrategyInstance 撤销交易权限，使用 StrategyCheckpoint、可用日志重放和重新 WarmupPeriod 恢复。
- 原始行情缺失记录为 capture gap，不伪装成零 ReplayRPO；研究数据仍按既定决策不承诺灾难恢复 RPO。
- 本地日志缺失不能覆盖 Venue 事实，也不能用推测消除 ReconciliationBreak。

### ReplayRPO limit

- 正常运行时每个 TradingShard 的热备重放落后必须同时满足时间差不超过 50 ms、shard sequence 差不超过 25,000 个事件，两者取更严格者。
- NodeFailure 或 NetworkPartition 后最终确认的不可重放尾部也不得超过该范围；超过即本次高可用目标失败，但仍可进入更慢的人工安全重建。
- PlannedSwitch 和可控 ProcessFailure 要求零序号缺口，不使用非计划故障宽限。
- 热备超过任一上限即进入 `HADegraded`，禁止自动切换并立即通知 SystemOwner。主节点作为唯一合法主节点可短时继续交易；连续 5 分钟不能恢复时禁止新增风险，只允许撤单、减仓和对账。
- 故障记录必须保存主节点最后已知 shard sequence、热备最后应用序号、实际缺口、可恢复来源及 ReplayRPO 判定。

### Automatic versus manual failover

- PlannedSwitch 只能由 SystemOwner 发起；发起后的受控步骤可以自动执行。
- ProcessFailure 优先由 supervisor 自动重启原进程。连续重启失败或状态不可复用时，只有旧进程 ExecutionCredential/交易租约已经撤销、NodeFence 已证明、ReplayRPO 为零且自动对账通过，才允许自动提升热备；否则保持 KillSwitch。
- NodeFailure 允许有条件自动提升，但必须由故障节点之外的控制模块成功建立 NodeFence，并使用 ObservationCredential 完成独立对账；心跳消失本身不构成提升授权。
- NetworkPartition 首版禁止自动提升。无法证明哪一侧仍能访问 Venue 时停止新增风险，避免双主。
- UntrustedState 永不自动提升；必须 KillSwitch、吊销或轮换凭证、使用干净节点重建并由 SystemOwner 恢复。
- Venue 外部故障不触发主备切换。
- 首版不建设 Raft、etcd 或通用集群选主；自动提升只依赖外部 NodeFence、单调 fencing token、Venue 对账和 SecurityAdmission 的严格条件路径。

### SafetyRTO and TradingRTO

`SafetyRTO` 从故障被检测到旧主不能再增加风险；`TradingRTO` 从当前主失去新增风险能力到新主通过全部准入并恢复新增风险。目标如下：

| 故障路径 | SafetyRTO | TradingRTO |
| --- | ---: | ---: |
| PlannedSwitch | ≤ 1 秒 | 目标 30 秒，硬上限 60 秒 |
| ProcessFailure：原进程重启 | ≤ 1 秒 | 目标 10 秒，硬上限 30 秒 |
| ProcessFailure：提升热备 | ≤ 1 秒 | 目标 30 秒，硬上限 60 秒 |
| NodeFailure：有条件自动提升 | ≤ 3 秒 | 目标 120 秒，硬上限 300 秒 |
| NetworkPartition：人工选边并完成 NodeFence 后 | ≤ 3 秒 | 目标 5 分钟，硬上限 15 分钟 |
| UntrustedState | 立即触发 KillSwitch | 不承诺固定 RTO，安全重建优先 |

- TradingRTO 包含 NodeFence、状态追赶、Unknown Order 处理、订单/成交/余额/仓位对账及 SecurityAdmission，不得恢复交易后再补做。
- 超过硬上限只表示高可用目标失败，不能因此跳过安全检查。
- Reduce-only、撤单和对账可以早于新增风险恢复，但必须使用已通过 fencing 的合法执行路径。
- Venue 外部故障的恢复时间不计入本地主备 RTO。

### PrimaryLease, FencingToken, and NodeFence

- fencing authority 位于交易节点之外，并按 ExchangeAccount + DecisionDomain 持久化分配严格递增、永不复用的 FencingToken。
- 当前主实例持有有效期 1 秒的 PrimaryLease，每 250 ms 续租；执行网关对每条 OrderCommand 检查租约未过期且 token 为当前代次。
- 续租失败时旧主在 1 秒内失去增加风险权限；执行网关本地拒绝过期租约，即使 TradingShard 仍在运行。热备不能预持有可交易 token，也不能同时续租。

提升顺序固定为：

1. 冻结候选新主的新增风险能力。
2. 撤销旧主 PrimaryLease。
3. 从节点外建立并验证 NodeFence；优先使用独立凭证吊销、Venue IP 白名单或外部防火墙规则。
4. 等待旧租约到期，并处理已提交但结果未知的在途命令。
5. 分配新的、更大的 FencingToken。
6. 完成状态追赶、Venue 对账和 SecurityAdmission。
7. 最后向新主授予新增风险权限。

- 请求建立 NodeFence 不等于已建立，必须读取外部控制状态确认。
- 主备共享 ExecutionCredential 且无法从外部证明旧节点被隔离时禁止提升。
- fencing authority 重启后必须从持久状态继续递增，禁止回退或复用 token。
- 旧 token 产生的迟到回报仍按 Venue 事实处理，但不能使旧主恢复交易资格。
- 旧节点重新加入时只能先作为无交易权限热备。

### FailoverAdmission

候选主先进入 `RecoveryOnly`，只允许撤单、Reduce-only 和对账；以下全部成立后才能进入 Active 并恢复新增风险：

- 身份与隔离：NodeFence 已从外部验证；旧 PrimaryLease 已过期或撤销；新 FencingToken 高于全部历史 token；新节点 MachineIdentity、ExecutionCredential 和出口 IP 匹配。
- 软件与配置：ReleaseArtifact 已批准且签名/哈希有效；状态 schema 与快照兼容；ConfigEvent、InstrumentRules、StrategyDefinition、StrategyLimit 和 AccountSafetyCeiling 版本完整一致。
- 状态与日志：快照校验通过；每个 TradingShard 重放到可证明末序号；ReplayRPO 在允许范围；有缺口的 StrategyInstance 已撤权并重新 warm-up；日志写入、快照和热备游标健康。
- Venue 对账：未完成订单、近期成交、余额和仓位查询完成；Unknown Order 已解决；OrderState、RiskReservation、PortfolioPosition 和 ExchangePosition 与 Venue 事实闭合；没有新增 ReconciliationBreak 或无法解释的 SuspenseAccount。
- 市场与风险：所需 L2 为 Live，标记价格和 InstrumentRules 未过期；RiskLease 重新签发，旧 RiskReservation 已重建或释放；KillSwitch 状态被继承且不能因切换自动解除。
- 节点健康：PTP/PHC、私有连接、日志、磁盘、io_uring 和 TelemetryPublish 健康。

任一检查失败只形成一个聚合原因并保持 RecoveryOnly，不得为满足 TradingRTO 跳过检查。

### Irreversible promotion and failback

- 一旦旧 PrimaryLease 被撤销或新 FencingToken 已分配，流程不可回滚到旧 token。
- 新主在 FailoverAdmission 中途失败时保持 RecoveryOnly 或 KillSwitch；不重新授权旧主。修复后使用当前 token 继续准入，或分配更高 token 切换到另一干净节点。
- 恢复的旧节点必须清除残留租约和凭证缓存，验证批准 ReleaseArtifact，从当前主取得快照及日志并完整重放，对账后只能作为热备加入。
- 首版禁止自动 failback。因维护需要回到原节点时，执行一次新的 PlannedSwitch，分配更高 FencingToken 并重新完成准入。
- 每次自动切换最多提升一个候选节点；失败后转人工处理，禁止在多个节点之间循环尝试。

### Failover scope

- 单个 TradingShard 进程故障优先在原节点独立重启该 DecisionDomain。执行网关仍可信且能确认旧 PrimaryLease/FencingToken 已撤销时，可以只提升该 DecisionDomain，其他 TradingShard 不停止。
- 执行网关故障、ExecutionCredential 异常或整机故障时，使用该执行网关和凭证的全部 DecisionDomain 构成一个 FailoverGroup；整组停止新增风险、完成 NodeFence 并切换到同一候选节点。
- 禁止将共享真实账户的一部分留在旧执行网关、另一部分交给尚未核对的新执行网关。
- NetworkPartition 和 UntrustedState 以节点及其全部 ExecutionCredential 为最小隔离范围，必要时扩大到整个 ExchangeAccount 或 Venue，不能缩小到单个 StrategyInstance。
- ExchangeAccount 对账在账户范围执行一次，再核对各 VirtualPortfolio、DecisionDomain 和 RiskReservation 的归属闭合。
- FencingToken 仍按 ExchangeAccount + DecisionDomain 递增，以支持可信节点上的单分片 ProcessFailure 独立恢复；NodeFence 和凭证隔离按 FailoverGroup 执行。

### Qualification and lightweight operations

- 自动提升路径首次启用前，必须在生产等价环境连续 3 次通过对应故障测试。
- ReleaseArtifact、内核、网络、凭证、fencing authority 或节点拓扑发生与该路径相关的变化时，重新测试受影响路径；真实故障暴露问题后，修复并重新取得三次资格。
- 正常蓝绿发布中的 PlannedSwitch 本身可以作为切换验证，不另行安排生产演练；不设置固定 90 天或其他日历式强制切换，也不让资格仅因时间经过而失效。
- 生产只持续执行非破坏性检查：热备游标、快照可读、ObservationCredential 对账、fencing authority 可达和 NodeFence 配置存在，不实际撤销租约或隔离主节点。
- 生产等价故障矩阵覆盖单 TradingShard/执行网关退出、整机断电、复制中断、两类网络分区、NodeFence 失败、旧 token 迟到、旧节点重现、Unknown Order、快照/日志损坏、对账差异及 FailoverAdmission 中途失败。
- 测试在正式日志、指标、风控和基准负载开启时运行，记录 SafetyRTO、TradingRTO、ReplayRPO、命令重复/遗漏和对账结果。
- 每次测试、实际故障或切换形成不可变 FailoverReport，由 RetentionPolicy 管理，不规定固定保存年限。
- UntrustedState 只在隔离环境演练凭证吊销和干净重建，不使用真实生产凭证模拟泄露。

### Open orders during failover

- 首版所有切换均采用切换前清空挂单，不设计跨版本保留 Venue 挂单的接管协议。
- PlannedSwitch 先停止新增风险，撤销 FailoverGroup 全部未完成订单，等待撤单结果，并经 REST 确认不存在 Live、PendingCancel 或 Unknown Order；随后完成近期成交、余额和仓位对账。
- ProcessFailure、NodeFailure 或 NetworkPartition 立即进入 KillSwitch/RecoveryOnly，由仍然合法且已 fencing 的执行网关撤销 FailoverGroup 全部挂单。
- 无法确认撤单结果的 Order 保持 Unknown，禁止恢复新增风险。
- 新主完成对账后，策略按当前市场重新产生新的 OrderIntent，不复用旧 OrderCommand。
- 该规则接受计划切换损失挂单队列优先级，以换取更简单可靠的双主防护、RiskReservation 重建和版本兼容；后期只有实测业务损失要求时才另行设计保留挂单切换。

### Fencing authority failure

- PrimaryLease 使用单调时钟截止时间，不使用 wall clock。主节点无法续租时不得本地延长、缓存或伪造租约；1 秒到期后停止新增风险。
- fencing authority 不可用时，当前主租约到期后进入 RecoveryOnly；不得提升热备，因为无法分配可信的新 FencingToken。
- 仍允许通过有效且已证明隔离的执行路径撤单、Reduce-only 和对账，并通知 SystemOwner；不自动 Flatten。
- 热备心跳正常、主节点心跳消失或 Venue 可达均不能替代 fencing authority 授权；节点间心跳只用于检测和告警。
- authority 部署在独立控制节点或独立故障域；首版不建设 Raft/etcd 集群，接受其故障暂停新增风险的单点可用性代价。
- authority 恢复后先验证持久 token 没有回退，再重新签发 PrimaryLease；不能自动解除 KillSwitch 或 RecoveryOnly。
