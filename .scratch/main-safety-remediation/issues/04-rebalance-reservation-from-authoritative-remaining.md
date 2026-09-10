# 04: 按权威剩余数量维护 RiskReservation

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 让 Canonical Venue 对账推进 OMS](02-apply-canonical-reconciliation-to-oms.md), [03 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](03-enforce-oms-intent-idempotency.md)
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
