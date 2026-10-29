# 06：显式 EnableTrading 接通策略输出与核心准入

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [05 Python 实例 checkpoint 与重启恢复](05-python-checkpoint-recovery.md)
Parent: [模块地图](../map.md)

## Question

如何使Ready实例只有在显式授权与Host激活屏障满足后才能提交可准入的策略输出？

## What to build

经现有Web显式启用Ready实例，将实际Python输出接入核心与Gateway共同准入，验证停用及迟到输出拒绝。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] Host实际应用HostActivated屏障后才使用当前StrategyActivationIdentity；发布成功和进程健康均不能代替EnableTrading。
- [ ] 运行适配层添加真实会话、激活、来源batch和cursor证据；包不能自行填写权威字段。
- [ ] OrderIntent及完整IntentGroup经现有核心归属、风险、账户/品种权限和Gateway发送前复核。
- [ ] 显式停用、SafetyGate关闭、旧HostSession或旧激活输出均拒绝新增风险；同VirtualPortfolio不能有两个获权实例。
- [ ] Web显示实际权限与失败原因；受控测试环境验证完整启停路径，本票不包含真实Venue下单授权。

## Answer / 实现证据

待实施。

