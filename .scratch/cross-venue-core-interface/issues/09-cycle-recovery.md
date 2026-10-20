# 09：周期恢复、经济承接与激活屏障

Type: task
Status: open
Assignee:
Blocked by: [09a 核心周期闭合](09a-cycle-closure-residual.md)、[09b 恢复与激活](09b-cycle-recovery-activation.md)
Parent: [模块地图](../map.md)

## Question

如何在恢复策略状态后追赶权威事实，并保留原周期风险与期限而不错误授予交易权限？

## What to build

贯通核心恢复、策略 checkpoint 与日志尾追赶、经济引用核对、账户对账和 HostActivationBarrier，使用与共同准入相同的占用权威。

## 完成条件

- [ ] 在 Entering、Repairing、Holding、Exiting、Reconciling 分别 checkpoint、崩溃、恢复，保持冻结计划、净收益目标、风险锁存与意图身份。
- [ ] 原期限包含停机时间；跨机时钟不可信时不虚构剩余预算，已触发退出不能恢复为 Holding。
- [ ] 预留成功但策略尚未观察时按原身份承接；不重复预留、消费机会或重发历史意图。
- [ ] 对账、迟到 Fill、基础币费用、费用更正、资金费及残余承接后资金与占用一致；Unknown、永续残仓不因恢复完成而消失。
- [ ] 周期完成与占用释放须由完整核心事实支持；未承接残余和未解决历史引用不能提前释放。
- [ ] schema/配置/模型不兼容、损坏 checkpoint、缺日志尾、旧会话和旧激活身份阻止错误激活，核心既有安全管理仍可履职。
- [ ] Keep/Migrate/Rebuild 与 StrategySuccessor 遵守身份和屏障合同，不重置经济事实、期限或锁存。
- [ ] 经公共恢复/激活接缝覆盖 I6–I8、S6-C–I/K/L/N–P；策略恢复不自动授权新开仓。

## Answer

2026-10-20 用户确认将实现拆为 [09a](09a-cycle-closure-residual.md) → [09b](09b-cycle-recovery-activation.md)，其中 09b 另依赖 08，09a 依赖 05b。本票保留原完成条件，作为汇总验收，不再独立领取；两票均通过且本票各项证据齐全后才能 resolved，10 的外部依赖继续指向本票。残余阈值与策略 schema/模型/参数冻结仍须提供证据，不能用架构确认替代。
