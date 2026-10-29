# 09b 实现合同与证据边界

日期：2026-10-29。基点 `0a3b26fd349e1feb82cb35e74272a60063676e71`；用户授权在 `codex/08-real-strategy-checkpoint` 完成09b。既有09合同的08依赖已解除；09a经济/残余政策沿用ADR0017/0018/0019，账户风险原因沿用ADR0021。

## 复用的权威与公共接缝

采用 `Owner.recoverInto/apply/checkpoint`、独立部署清单锚点、按账户认证的 reconciliation cursor/archive、原 `cycles` 与 OMS身份、08 Repository/ManagedHost/ComponentRuntime、已有 `HostActivated` 和 Gateway。新增协调对象只保存有界暂态资格，不拥有或恢复第二份余额、订单、风险或占用表；不改变journal/state/registry格式。

`Recovery.begin`要求核心已撤销开仓权限、当前Owner稳定、清单锚点独立绑定；旧Host授权经Owner持久撤销。新session必须绑定当前fencing。策略恢复期间核心安全工作仍独立存在。

恢复来源必须是已提交Repository引用，校验版本/元数据/哈希后通过真实pipe追赶。提交资格前，核心逐个核对整个域账户：新的已提交对账根、无待闭合窗口/经济事实/未知经济时间/经济故障/Suspense/OMS recovery-only、账本闭合，Unknown订单仍拒绝。余额、费用、保证金及多Asset内容沿既有认证对账根，不能用单账户净额代替。

资格绑定当前核心屏障和CanonicalStateDigest、精确私有Metadata及StrategyStateDigest；所有本策略活动核心周期必须由唯一私有组件覆盖。冻结依赖摘要由包的可信配置提供，组内容摘要取自核心原周期；周期/预留引用使用显式 `cycle:<strategy>:<first sequence>`、`reservation:<strategy>:<first sequence>` 字符串。完整投影的bytes SHA256由核心侧计算，私有经济引用绑定 `economic:<cursor>:<digest>`；Python不能自行宣称另一个核心事实。

Holding按原成员、方向及可信包声明的base单位精确核对两腿matched_base。线性仓位由native lots及quantity numerator/denominator/atomic scale换算；现货排除已归旧周期的残余。有理数沿v2的i128/u128范围，交叉相乘使用u256；非法单位、规则不匹配及溢出拒绝。Repairing不得伪称核心不存在的敞口，Completed必须由既有核心闭合证明支持。

next IntentSequence同时受热OMS身份及已提交认证冷历史约束。查询next及其同策略有序upper witness，避免空洞序号绕过更大的归档身份；缺页、失败或retired/floor不足以证明时拒绝。不得从OMS累计猜唯一经济成交。

活动周期issued逐项对应原place command、订单、cycle、账户/组合/品种、方向、数量、价格、规则及TIF。无权重放新生成但核心从未接纳的意图不能获得激活。已观察拒绝且pending已清除的身份，须有热SeenIntent、无接受命令、冷历史中不存在归档接受身份的认证证明；其描述不被当成经济成交或订单。部分归档留下SeenIntent不能冒充拒绝；仍pending或身份不明时继续拒绝。

支持每实例最多16个绑定、每次最多64个私有组件，重复周期或组件拒绝；达限不删除未解决事实。组件v2和既有三流Repository容量继续适用，不承诺无限生命周期。

`Recovery`为显式allocator生命周期的opaque句柄，资格留在私有State；返回Ticket为诊断副本，不能写回权限。`activate`只消费协调对象自己产生的资格。若屏障/摘要、fencing、策略cutover状态或权限改变则重验，不能由调用方传入一组“验证成功”布尔值。Owner先持久提交原有HostActivated：其中摘要仍是核心CanonicalStateDigest；送给Host的Activation独立绑定私有StrategyStateDigest，二者不互相替代。

Owner恢复后的`recovery_admission_pending`必须先通过既有绑定RawIngress及穷尽重放公共接缝解除；账户对账或Host恢复完成不能替代这道进程准入屏障。未完成时拒绝Host激活，核心安全管理继续独立工作。

## Host激活与业务身份

portable入口增加显式激活处理，仍是现有72-byte control payload。必须匹配策略、受控入口指定的新activation identity、当前完整私有摘要和紧接当前cursor的核心激活事实屏障。Host先按连续输入覆盖该事实，随后才发布新的实际Cycle Action；无权重放仍推进原序号并保存阶段/期限/计划，但绝不发布历史意图。新输出重新走既有Gateway及核心共同准入，旧session/activation均无效。

核心与Host恢复均不执行EnableTrading/Resume。查询、已有撤单和安全减险仍由原核心权限约束；当前Host输出codec尚无任意订单查询/撤单RPC，不能把Python私有引用直接解释为OrderCommand。完整Maker–Taker执行模式资格仍归10及策略运行验收。

## 时间与版本转换

本次激活仅支持包配置明确声明的UTC时间轴；默认unverified拒绝资格，不能直接把另一台机器的单调值当UTC。时间取自持久输入及认证账户cursor的共同UTC高水位。协调对象保存已观察UTC及屏障；回退则拒绝。轮转后若未观察的日志区间已丢失而不能证明时序，须重新建立恢复锚点，不能回退时间预算。每个周期须应用当前真实投影；原持仓/修复/退出deadline不重置，已到期但尚未进入退出/安全处置状态的周期不能激活。没有可信UTC证据时保留核心风险及安全管理，不猜剩余期限。

包内 `transition_checkpoint` 显式处理Keep/Migrate/Rebuild。Keep保持原内容及完整元数据；Migrate要求包提供明确模型迁移函数，固定周期/计划、标签、请求、风险、期限、序号不得被模型迁移覆盖。Rebuild只重新预热窗口/filtered模型，保留未成熟标签、旧周期和风险原因；新增rebuild锁并撤销监测资格，不能自动恢复开仓。转换结果仍需Host恢复、核心对账及新屏障；不是授权。

当前v2冻结计划仍绑定原实例/配置。把活动周期直接换成新config或Successor身份明确拒绝，不借升级重置经济归属；Successor采用既有核心VersionActivation/组合归属与新私有状态，不能恢复旧实例权限。其他schema迁移/跨配置活动计划转换需要单独兼容实现，不能用本接口冒充已经支持。

## 验收范围

沿用09已经约定的真实ManagedHost输入/输出、Checkpoint发布/文件重开、Owner/Store、核心规范事件、Gateway激活接缝。私有阶段测试从实际Cycle公开方法生成Entering/Repairing/Holding/Exiting/Reconciling，不人工填状态。核心链路使用真实双账户组、认证对账与唯一原周期；未观察的已提交预留通过原身份承接并消费原Signal，不二次预留。Signal/Admission/Monitor也经真实Host恢复；过期机会保留已用评估次数，清除restart不清日损失或InvalidLatched。

目标8、匹配一半、修复亏损1使用规范减仓Fill及核心realized_pnl。恢复后的冻结目标仍4，剩余净贡献要求5；新激活后的实际边界决策及安全输出须经Gateway/Owner回到原周期。Maker撤单在途迟到Fill及hedge Unknown使用原生post-only及规范报告/Fill；Unknown未查明时拒绝激活且不盲目对冲。完整模式和Venue运行资格仍由10负责。

测试中的数据为明确离线夹具/投影；没有真实Venue或生产canonical日志资格，没有部署或交易。Windows本机证据不代表Linux/其他Python、跨机可信时钟或断电资格。09汇总及10不随本次实现自动关闭；最终命令、结果、审查和剩余限制记录在09b验证文档。
