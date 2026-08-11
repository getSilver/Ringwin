# 定义生产操作生命周期

Type: grilling
Status: resolved
Blocked by: 20, 24
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

启动、预热、启用交易、暂停、撤单、降低风险、停机、恢复、发布、回滚和应急处置分别经过哪些状态、检查和人工确认？

## Answer

### 状态模型

每个可操作范围（StrategyInstance、DecisionDomain 或 FailoverGroup）只使用五种 OperationalMode：

1. **Stopped**：未运行或已经安全停机。
2. **Recovering**：加载快照、重放、预热和对账，不得增加风险。
3. **Ready**：所有准入检查已经通过，但尚未取得启用交易的授权。
4. **Trading**：允许在有效凭证、租约和风险额度内增加风险。
5. **Draining**：禁止新增风险，撤销挂单并完成对账，完成后进入 Ready 或 Stopped。

KillSwitch、行情健康、TradingCredential、PrimaryLease、RiskLease 和 fencing 状态是独立 SafetyGate，不扩展为 OperationalMode 的组合状态。任一必需 SafetyGate 关闭都会立即撤销新增风险能力。

WarmingUp 只描述 StrategyInstance 尚未形成合格策略状态；RecoveryOnly 只描述当前权限只允许撤单、Reduce-only 和对账。两者不与 OperationalMode 重复定义。

### 正常启动与首次启用交易

正常启动采用以下路径：

1. Stopped 进入 Recovering，启动已批准且签名和哈希匹配的 ReleaseArtifact。
2. SystemOwner 手工解密节点所需 TradingCredential；交易进程不能绕过该要求。
3. 验证节点基线、MachineIdentity、时间同步、网络出口、凭证权限、账户模式、白名单、AccountSafetyCeiling 和 fencing authority。
4. 加载快照并重放日志，恢复订单、账本、持仓、RiskReservation 和 StrategyPrivateState。
5. 建立行情与私有连接，并通过 REST 完成订单、成交、余额、仓位及 Unknown Order 对账。
6. 订单簿健康、策略预热、热备状态及 SecurityAdmission 和适用的 FailoverAdmission 全部通过后，自动进入 Ready。

Ready 仍不得增加风险。正常冷启动、维护后启动或人工恢复必须由 SystemOwner 签发 EnableTrading ControlCommand，控制面展示目标范围、账户、策略、风险额度、当前仓位、未解决差异和 SafetyGate 汇总，并显示 RiskWarning；普通确认后形成 TradingAuthorization。人工确认不能跳过任何失败的准入检查。

唯一例外是此前已处于 Trading 的范围发生符合既定自动恢复条件的 ProcessFailure 或 NodeFailure：完整通过 FailoverAdmission 且原 TradingAuthorization 未被撤销时，可以自动恢复 Trading。KillSwitch、NetworkPartition 和 UntrustedState 不得继承该授权。

### 暂停与一次性撤单

- TradingPause 是持续状态变更：目标范围从 Trading 进入 Draining，立即停止产生和接受新增风险的意图，撤销该范围全部未完成订单并完成 REST 对账，然后进入 Ready。
- TradingPause 不自动平仓；现有持仓继续保留并正常记账、估值和监控。
- 人工暂停会撤销该范围的 TradingAuthorization。重新交易必须由 SystemOwner 再次执行 EnableTrading，不能因行情恢复或进程重启自动解除。
- CancelOpenOrders 是一次性 ControlCommand：撤销指定订单或范围内当前可见的未完成订单，但不改变 OperationalMode。
- 在 Trading 下执行 CancelOpenOrders 后，策略可以在后续事件重新报单；控制面必须提示需要持续保持空挂单时应使用 TradingPause。
- 两类命令都具有明确范围和幂等身份；Unknown Order 必须继续对账，不能视为已经撤销。

### 降低风险与全部平仓

- DeRisk 是 SystemOwner 发起的受控减仓操作，目标是明确的最大仓位或最大名义敞口；Flatten 是目标敞口为零的 DeRisk。
- 目标范围进入 Draining 后先停止新增风险并撤销全部挂单，再只允许 Reduce-only 订单向目标敞口靠近。
- 控制面展示当前仓位、目标仓位、盘口、预估滑点、最大下单量和影响范围，并显示 RiskWarning；SystemOwner 普通确认即可。
- 第一版只提供限价和受限价格保护的 Reduce-only 执行，不建设 TWAP、VWAP 或智能执行框架。
- 达到目标并完成订单、成交、余额和仓位对账后进入 Ready；未完全成交时保持 Draining 并明确显示剩余敞口，不得把部分完成报告为成功。
- 自动风控、行情异常或凭证异常只触发 KillSwitch，不会自行 DeRisk 或 Flatten。

### 正常停机与强制终止

正常停机必须：

1. 撤销 TradingAuthorization 并进入 Draining。
2. 停止新增风险，撤销全部未完成订单，并确认不存在 Live、PendingCancel 或 Unknown Order。
3. 完成订单、成交、余额、仓位和账本对账。
4. 提交决策日志、生成可恢复快照并确认热备追平；计划停机要求 ReplayRPO 为零。
5. 释放 PrimaryLease 和交易权限，关闭私有连接并清除内存中的 SecretMaterial，然后进入 Stopped。

正常停机不强制平仓。SystemOwner 必须明确选择 KeepPositions 或先执行 DeRisk/Flatten；KeepPositions 时控制面展示币种、数量、名义价值、保证金和清算风险的 RiskWarning。停止单个策略时持仓继续归属于原 VirtualPortfolio。关闭仍有持仓的主节点时优先 PlannedSwitch 到热备；若选择无接管停机，至少保留独立只读对账和告警能力，并形成带持仓停机的 OperatorRecord。

存在未解决 Unknown Order、ReconciliationBreak 或日志提交失败时不能标记为正常 Stopped。SystemOwner 仍可执行 ForcedStop，但必须保留未完成原因，下一次启动只能从 Recovering 开始并完成全面对账。

### SafetyGate 恢复

SafetyGate 按是否可能留下未知经济或身份事实分为两类：

- **SelfRecoveringGate**：短暂行情缺口完成快照重同步、策略重新预热完成、RiskLease 获得有效新版本，以及遥测恢复且本地状态连续。这些故障期间 OperationalMode 可以保持 Trading，但有效权限降为 RecoveryOnly；全部验证通过后可继承原 TradingAuthorization 自动恢复。
- **LatchedSafetyGate**：KillSwitch、TradingPause、Unknown Order、ReconciliationBreak、TradingCredential 异常、PrimaryLease 或 fencing 不确定、日志或快照损坏、NetworkPartition 和 UntrustedState。这些情况撤销 TradingAuthorization，恢复后最多进入 Ready，必须由 SystemOwner 再次 EnableTrading。

只有系统能确定性证明状态连续、Venue 没有未知效果且身份权限没有改变时才允许自动恢复。自动恢复前，订单簿必须健康、策略必须追平当前屏障，风险和安全准入必须重新通过。SafetyGate 关闭不自动触发 Flatten；多个故障并存时，只要一个属于 LatchedSafetyGate，整体就按锁存故障处理。

### 发布与回滚

- SystemOwner 对明确目标范围和 ReleaseArtifact 或 ConfigEvent 内容哈希执行一次 DeployRelease ControlCommand。控制面展示版本差异、影响范围、StrategyStateTransition、预计停单范围和资格结果，并显示 RiskWarning。
- 单人系统不把批准、部署和切换拆成三次人工确认；一次确认授权完整受控流程，后续步骤自动执行。
- 候选版本先以无交易权限方式加载，完成 schema 检查、Migrate 或 Rebuild、影子重放及健康验证；当前版本继续交易。
- 候选合格后自动执行 PlannedSwitch：目标范围进入 Draining，完成 CutoverDrain，在 CutoverBarrier 写入并确认 VersionActivationEvent，然后新版本继承原 TradingAuthorization。
- 参数更新使用同一流程，但候选载荷是版本化 ConfigEvent；仍撤销受影响 StrategyInstance 的挂单。
- 激活前失败只丢弃候选，当前版本继续运行。
- 激活后故障会自动关闭新增风险并告警，但不得自动加载旧状态或暗中切回。SystemOwner 可以发起 ForwardRollback，它复用相同发布流程并只恢复旧代码。
- 第一版只保留当前版本和一个已批准的前一版本作为快速回滚候选，不建设多版本发布编排器。

### 应急处置

1. 自动风控或 SystemOwner 可以立即触发最小必要范围的 KillSwitch，触发本身不等待确认；无法确定影响范围时扩大到 ExchangeAccount、Venue 或全局。
2. 执行网关立即拒绝新增风险并撤销挂单，仍允许合法撤单、Reduce-only 和对账，不自动 Flatten。
3. 怀疑节点失控时从节点外建立 NodeFence；怀疑 TradingCredential 泄露时在 Venue 吊销凭证；怀疑控制面或发布密钥时停止配置和发布并扩大 KillSwitch。
4. 控制面不可用时，本地紧急控制台只能触发 KillSwitch。系统执行路径也不可用时，SystemOwner 可以在 Venue 官方界面撤单或吊销凭证；这些外部操作随后按 Venue 事实对账，不能伪造成内部事件。
5. 使用独立 ObservationCredential 核对订单、成交、余额和仓位；存在 Unknown Order 或 ReconciliationBreak 时保持 LatchedSafetyGate。
6. 恢复必须使用可信节点、批准 ReleaseArtifact、有效新凭证和完整日志与对账，从 Recovering 进入 Ready，再由 SystemOwner查看汇总和 RiskWarning 后重新 EnableTrading。
7. 每次事故只形成一条聚合 OperatorRecord，关联既有 KillSwitch、凭证、对账和交易事实；不建设复杂事故工单或逐步骤审计系统。

### 范围继承与并发操作

- EffectiveTradingAuthority 是当前对象及全部上级范围 SafetyGate 的交集。StrategyInstance 即使自身处于 Trading，只要所属 DecisionDomain、FailoverGroup、ExchangeAccount 或全局范围被暂停或锁存，就不能增加风险。
- 扩大限制立即向下生效；解除上级限制不会自动启用子范围，子范围原有 TradingPause 和 LatchedSafetyGate 仍保留。
- 每个目标范围同一时刻只允许一个 LifecycleOperation。Pause、DeRisk、停机、发布和恢复冲突时，后到 ControlCommand 明确拒绝，不排队猜测顺序。
- 更大范围的 LifecycleOperation 锁定其子范围；例如账户级 Draining 期间不能单独发布某个 StrategyInstance。
- KillSwitch 可以随时抢占任何 LifecycleOperation，不受操作锁限制。
- 所有命令使用 command_id、目标版本前置条件及幂等结果；重试不得重复撤单、发布或平仓。
- 长流程只暴露 operation_id、当前阶段、开始时间、目标和最终结果，不建设通用工作流引擎。

### 长流程失败与超时

- 撤单、对账、状态追赶、发布切换和减仓都有阶段截止时间；具体时限取自 Venue 能力契约和既定 RTO，不设置一个全局固定值。
- 任一阶段失败或超时后停止向后推进，目标范围保持 Draining、Recovering 或 RecoveryOnly，不得把超时视为成功。
- 撤单超时的 Order 进入 Unknown；对账不闭合形成 ReconciliationBreak；两者都会成为 LatchedSafetyGate。
- SystemOwner 可以幂等重试当前阶段、继续等待、扩大 KillSwitch、在执行路径可信时执行 DeRisk，或最终 ForcedStop。
- 失败后不自动反向执行整条流程；发布失败不恢复旧经济状态，DeRisk 部分成交也不反向加仓。
- KillSwitch 抢占 LifecycleOperation 后，该操作标记为被安全中止；解除 KillSwitch 不会自动续跑，必须由 SystemOwner 明确重试或重新发起。
- 操作结果只汇总首要失败原因及相关 Unknown Order 或 ReconciliationBreak，不为每个内部步骤制造审计事件。

### 人工确认矩阵

以下操作无需阻塞确认并立即执行：

- 自动或人工触发 KillSwitch；
- SafetyGate 自动关闭；
- 符合条件的 SelfRecoveringGate 自动恢复；
- 已经由 DeployRelease 授权的发布流程内部步骤。

以下操作要求有效 OwnerSession，但不额外显示 RiskWarning：TradingPause、CancelOpenOrders、正常无持仓停机、重试失败流程的当前安全阶段，以及只读查看状态、日志和对账结果。

以下操作要求有效 OwnerSession，并在展示一次 RiskWarning 后由 SystemOwner 普通确认：EnableTrading、DeRisk、Flatten、KeepPositions 停机、ForcedStop、DeployRelease、ForwardRollback、PlannedSwitch、提高风险额度、扩大交易范围和解除 KillSwitch。

所有操作都不要求双人审批、硬件签名或操作级 TOTP；TOTP 只用于建立 OwnerSession。

### 首版验收

- 冷启动逐项注入 ReleaseArtifact、TradingCredential、时间、行情、快照、日志、策略预热和对账失败，验证任一失败都不能进入 Trading。
- 验证 Ready 只有收到有效 EnableTrading 后才进入 Trading。
- 验证 TradingPause 持续停单并清空挂单，而 CancelOpenOrders 后策略仍可重新报单。
- 验证 DeRisk 部分成交、拒单和超时不会反向加仓，也不会虚报完成。
- 验证正常停机达到订单、账务和日志闭合；ForcedStop 后重启必须完整恢复。
- 分别验证 SelfRecoveringGate 自动恢复和 LatchedSafetyGate 人工恢复，确保不会错误继承 TradingAuthorization。
- 在发布激活前后注入故障，验证激活前保留当前版本，激活后只能安全停单或执行 ForwardRollback。
- 并发发送冲突 ControlCommand 并让 KillSwitch 抢占，验证不存在排队乱序、重复撤单或重复减仓。
- 模拟控制面不可用，验证本地紧急控制台只能 KillSwitch，Venue 外部操作能够通过后续对账恢复。
- 验证相同 ControlCommand 重放不会重复产生外部效果。

这些测试在相关路径首次启用或发生实质变更时执行；不要求固定周期演练，也不新增独立运维 SLA，继续使用既定 SafetyRTO、TradingRTO 和发布资格标准。
