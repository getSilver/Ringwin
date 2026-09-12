# 11: 实现可重放的订单容量与终态墓碑

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [03 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](03-enforce-oms-intent-idempotency.md), [04 按权威剩余数量维护 RiskReservation](04-rebalance-reservation-from-authoritative-remaining.md), [10 删除竞争订单状态与废弃经济投影](10-contract-legacy-state-and-projection.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让长期运行中的终态订单退出热 OMS 容量，同时永久保留幂等、对账、审计和 predecessor 所需证据？

## What to build

为终态 Order 建立确定性墓碑/归档流程。只有不再可能接收合法迟到事实、reservation 已闭合且审计摘要已提交的订单才能离开热表；容量或归档不可用时进入 RecoveryOnly，不覆盖旧条目。

## Acceptance criteria

- [x] 终态墓碑保留 OrderIdentity、OrderIntentIdentity、ClientOrderId、最终 revision/state、累计成交、predecessor、关键事实身份和内容摘要。
- [x] 迟到重复事实仍为 no-op，迟到冲突或墓碑之外的不可解释事实锁存 ReconciliationBreak。
- [ ] 活跃、Unknown、PendingCancel、未闭合 reservation 或仍被 CCC 引用的 Order 永不淘汰，且合法迟到事实窗口已结束、审计摘要已提交。
- [x] 墓碑创建和热表释放在同一持久 barrier 上提交；崩溃恢复不会同时丢失热 Order 与墓碑。
- [x] 超过当前玩具上限的长期订单轨迹、registry/gateway gate 容量和重启恢复有确定性压力验收；耗尽时明确 RecoveryOnly。

## Out of scope

- 无限内存、静默覆盖最旧订单或在没有测量前引入外部数据库框架。

## Answer

部分完成：墓碑保留完整终态 report/reconciliation、精确迟到重复 no-op、冲突与容量耗尽进入 RecoveryOnly；尚缺可验证的归档窗口结束及审计摘要提交资格事实。
