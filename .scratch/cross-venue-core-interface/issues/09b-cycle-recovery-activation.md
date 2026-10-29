# 09b：策略恢复与核心占用联结

Type: task
Status: resolved
Assignee: Codex
Blocked by: [08 确定性 checkpoint](08-deterministic-checkpoint.md)、[09a 核心周期闭合](09a-cycle-closure-residual.md)（均已完成）
Parent: [模块地图](../map.md)

## Question

如何让策略 checkpoint 追赶核心周期事实并通过激活屏障，同时保留原计划、期限和退出锁存？

## What to build

串联 08 的确定性私有状态与 09a 的核心闭合事实，经权威恢复、Cursor 追赶、账户对账和新 activation 联结原周期。遵守 [ADR0017](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md) 和 [状态恢复合同](../../cross-venue-arbitrage/state-recovery-contract.md)，策略只保存核心引用。

## 完成条件

- [x] Entering/Repairing/Holding/Exiting/Reconciling 分别 checkpoint、崩溃、恢复，保持冻结计划、净收益目标、风险锁存、下一意图身份与原周期关联；预留已提交但未观察时按原身份承接。
- [x] 核心先恢复并对账，再按 Cursor 追赶到新 HostActivationBarrier；旧会话/激活输出无效，不重复消费机会、预留或重发历史意图。
- [x] 原期限包含停机时间，跨机时钟证据不足不能虚构剩余预算；退出不能恢复为 Holding，Unknown、永续残仓与残余待承接不能因恢复完成被清除。
- [x] schema/配置/模型不兼容、损坏 checkpoint、缺失/冲突尾部、超容量与数值溢出拒绝错误激活；独立核心安全管理仍能处理撤单与安全事实。
- [x] Keep/Migrate/Rebuild 与 StrategySuccessor 保留经济事实、期限和锁存；策略摘要不能替代核心摘要或发送授权。
- [x] 经公共恢复/激活路径比较连续运行与恢复，覆盖 I6–I8、S6-C–I/K/L/N–P，并引用 09a 经济承接证据；记录实际版本、命令、故障切点与局限。

## Answer

2026-10-29 在用户指定的 `codex/08-real-strategy-checkpoint` 完成。实现为 `00438d84`、`1c4f169e`、`9d0272ea`；资格由核心私有协调对象核对并经 Owner 持久提交，真实 Host 从文件 checkpoint 追赶，原周期/经济归属/序号/期限/风险保留，恢复不开放新增风险。

最终 Python 243/243、ReleaseSafe 819/819、Host 产品 28/28，均 exit 0；两轴复审无遗留阻断。具体公共链路、切点、S6/I6–I8 对照、09a 经济引用及拒绝场景见 [验证记录](../09b-verification.md) 和 [实现合同](../09b-implementation-contract.md)。

按 Windows 本机离线范围 resolved；无真实 Venue、跨平台、跨机时钟或生产资格，无部署或交易。09 汇总验收与 10 保持未关闭；本票不修改来源策略 spec。
