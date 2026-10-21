# 04：Host 完整 IntentGroup 原子传输与身份校验

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何让 Host 一次提交完整双腿决策，并在核心边界原子验证其身份与完整性？

## What to build

通过真实 StrategyHost framing 向核心入口传输有界完整 IntentGroup，稳定绑定成员顺序、连续 IntentSequence、策略身份、cursor、会话、激活与配置证据。

## 完成条件

- [x] 公共 Host 输出路径可解析两账户两成员组；合法完整组作为一个候选进入核心边界，不拆成两条独立新风险请求。
- [x] 覆盖旧会话/激活身份、过期 cursor、重复或冲突序号、冲突策略身份、半帧、半组及容量失败。
- [x] 每种失败明确记录身份是否消费、拒绝事实及预留/命令是否产生；非法组不能留下半组副作用。
- [x] Python 不能提供权威 RiskDecision、Reservation、OrderCommand 或 ClientOrderId。
- [x] 公共 framing、候选身份持久化及重放行为一致；单意图与组输出的版本兼容有明确规则。
- [x] 未完成共同准入时只能证明完整传输与边界验证，不能开放双账户发送权限；覆盖 I2 的入口部分。

## Answer

2026-10-21 完成离线实现与验收。明确合同、身份消费表及兼容规则见 [04 合同](../04-host-group-contract.md)，实际命令和局限见 [04 验证](../04-verification.md)。

- 真实 Python pipe 经 Gateway 将两个账户的两个连续成员作为一个有界完整候选交给 TradingShard.applyStable；schema 1 单意图保持原合同，schema 2 显式表示完整组，传输最多 4 成员、448 bytes。
- 复用 OMS 的持久组/成员身份。业务 SHA-256 独立于会话、batch、cursor 和激活包络；原始完整包络仍进入稳定输入摘要。跨快照及实际会话/激活更换后，相同业务组仍去重。
- 完整授权组的 stale/cursor 拒绝和 joint_admission_unavailable 一起消费全部成员身份；无效包络不消费身份。冲突、半组、Trace 容量及日志失败不产生半组身份、预留或命令。
- 日志重放、快照恢复和本地 FileAdapter commit / 快照发布 / 关闭重开恢复相同摘要及 8 个成员身份、0 个命令。journal 41 / state 45 / registry 39 精确拒绝旧的不兼容持久版本。
- ReleaseSafe 主回归 **652/652**、Host 产品验收 **14/14**、Python 边界 **5/5**、构建和格式检查通过。修正了故障隔离验收将无关夹具初始化时间计入健康输出新鲜度的测试问题；产品 100 ms 限制未变。
- Standards / Spec 双轴审查及最后增量复核均无剩余发现。

本票仅完成 I2 入口。共同准入、账户及路由资格、周期占用和发送仍由 05a/05b 与后续执行票验收；所有组路径保持双账户新增风险权限关闭，不关闭来源 spec，不授予任何线上资格。
