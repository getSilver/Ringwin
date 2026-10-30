# 06：显式 EnableTrading 接通策略输出与核心准入

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 Python 实例 checkpoint 与重启恢复](05-python-checkpoint-recovery.md)
Parent: [模块地图](../map.md)

## Question

如何使Ready实例只有在显式授权与Host激活屏障满足后才能提交可准入的策略输出？

## What to build

经现有Web显式启用Ready实例，将实际Python输出接入核心与Gateway共同准入，验证停用及迟到输出拒绝。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] Host实际应用HostActivated屏障后才使用当前StrategyActivationIdentity；发布成功和进程健康均不能代替EnableTrading。
- [x] 运行适配层添加真实会话、激活、来源batch和cursor证据；包不能自行填写权威字段。
- [x] OrderIntent及完整IntentGroup经现有核心归属、风险、账户/品种权限和Gateway发送前复核。
- [x] 显式停用、SafetyGate关闭、旧HostSession或旧激活输出均拒绝新增风险；同VirtualPortfolio不能有两个获权实例。
- [x] Web显示实际权限与失败原因；受控测试环境验证完整启停路径，本票不包含真实Venue下单授权。

## Answer / 实现证据

### 2026-10-31 实现

- 在指定工作树、分支 `codex/strategy-package-03` 实施，起点 `0676beea`。复用现有 Web RiskWarning/签名命令路由；确认绑定实例，实例命令的 UTC 秒在签名前转换为核心 UTC 纳秒。
- 原生 `strategy_package_authority.Authority` 借用现有单 Writer 的 TradingShard/journal，通过其 commit 回调提交；不初始化账户、分配资金或另建交易权威。现有节点私有连接缺失时拒绝启用。
- 核心先提交 EnableTrading 和 HostActivated，运行适配器经现有 ManagedHost 发送激活和覆盖屏障的 batch，校验 Host 的精确 cursor ACK 后才激活 Host Gateway。Ready 可继续无权追赶，按正常回调消耗序号；陈旧 Ready 拒绝启用但保留追赶机会，不能放宽屏障。
- 真实批准包的固定 API OrderIntent/完整 IntentGroup 由 Host 包装来源证据，经过现有 native ingress、核心共同准入和 execution Gateway；运行输入复用恢复的逐事件规范化，包不可填写风险审批、命令或 Gateway 权威字段。
- 显式停用先撤销核心权限再停止 Host。后台监测 Host 死亡和核心撤权；异常通过既有 fault/latch 接缝关闭权限。pipe 写入与读取共用有界期限，失败连接不复用迟到响应，撤权确认不可得时明确报告 unknown 原因。
- Web 显示当前权限及拒绝原因；停止、重启和回放不恢复交易权限。当前仍沿用单 resident Host 容量，第二实例不能同时获权，多实例能力留给10。

### 验证与资格边界

Windows Python 最终全量306项：292通过、14平台skip，exit 0；ReleaseSafe核心821/821，3/3步骤通过、exit 0。正常构建9/9、原生验收节点构建3/3，UI断言、格式与静态检查通过，双轴复审无剩余发现。并发恢复进度回归暴露的OwnerSession续期竞争已在共享事务处加锁，覆盖并发续期与撤销不可复活。详见[验证说明](../evidence/06-validation.md)，其中保留中间失败及其修正，不将其冒充通过。

使用真实签名包、解释器、Host、现有单账户及多账户核心 fixture、durable MemoryAdapter 和真实 execution Gateway，Venue 为模拟实现。没有访问凭证、执行 Demo/真实 Venue 订单、发布或部署，不授予生产资格。Windows verification file adapter 不证明断电耐久性；Linux 资源资格依 ADR0010 继续单列。

