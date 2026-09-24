# 04: 按权威剩余数量维护 RiskReservation

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (03 resolved)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让部分成交、amend、cancel、终态与对账都按同一权威 remaining quantity 更新 RiskReservation，而不提前释放或永久保留整单占用？

## What to build

把 reservation 重算收口到 OMS 的订单状态转换：每次权威数量或终态变化都生成确定的占用变化，TradingShard、AccountCoordinator 和 replay 只消费同一结果。

## Acceptance criteria

- [x] 部分成交后 reservation 按剩余数量和当前已确认规则重算，费用与保证金继续覆盖最坏可成交结果。
- [x] PendingAmend、PendingCancel、Submitted 和 Unknown 保留必要占用；只有权威终态或严格 ConfirmedAbsent 才释放。
- [x] amend 在旧/新 reservation 间使用保守上界，确认后才切换；失败或 Unknown 不提前归还额度。
- [x] layered risk、GrossPortfolioMargin、SafetyGate 和摘要只使用 OMS 导出的当前 reservation，不再依赖遗留单标量。
- [x] 多订单、部分成交、迟到回报、重复对账及重启恢复的 live/replay 占用轨迹完全一致。

## Out of scope

- 跨 VirtualPortfolio 净额抵消或把 AccountNettingBenefit 转为购买力。

## Answer

RiskReservation 已由 OMS 权威剩余数量按状态保守维护，部分成交、amend、cancel、Unknown 与恢复路径共享同一投影。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R04-A](../review-repair-plan-2026-09-23.md#04pendingamend-期间的占用)要求补证：PendingAmend 期间部分成交不抹掉修改请求，也不把新单最坏占用提前释放；amend 拒绝只撤销修改请求，原 live Order 和 reservation 仍在。验证成交→确认/拒绝/Unknown 与重启的 live/replay。

## 2026-09-24 修复与复验

`src/oms.zig` 在 PendingAmend 中保留旧单已确认数量、规格及新目标剩余占用；旧 revision 成交只重算旧单剩余量，待决占用取旧/新上界。Unknown amend 收到旧成交或旧 revision 对账仍阻断新发送；拒绝恢复旧单 revision、规格及剩余占用；新 revision 的权威确认才切换。异常数量和累计成交回退稳定拒绝。`src/trading_shard.zig` 的完整及语义摘要覆盖待决恢复状态。OMS 与 TradingShard 公共入口回归覆盖多订单、成交→确认/拒绝、Unknown、异常对账、状态拷贝与事件重放摘要一致。Debug 使用 Windows 64 MiB 测试栈；ReleaseSafe 使用默认测试栈，均为 275/275。仅离线证据，Linux/Venue/生产资格不变。
