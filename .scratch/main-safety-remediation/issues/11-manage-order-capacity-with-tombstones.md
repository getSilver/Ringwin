# 11: 实现可重放的订单容量与终态墓碑

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (04、09、10 已收口)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让长期运行中的终态订单退出热 OMS 容量，同时永久保留幂等、对账、审计和 predecessor 所需证据？

## What to build

为终态 Order 建立确定性墓碑/归档流程。只有不再可能接收合法迟到事实、reservation 已闭合且审计摘要已提交的订单才能离开热表；容量或归档不可用时进入 RecoveryOnly，不覆盖旧条目。

## Acceptance criteria

- [x] 终态墓碑保留 OrderIdentity、OrderIntentIdentity、ClientOrderId、最终 revision/state、累计成交、predecessor、关键事实身份和内容摘要。
- [x] 迟到重复事实仍为 no-op，迟到冲突或墓碑之外的不可解释事实锁存 ReconciliationBreak。
- [x] 活跃、Unknown、PendingCancel、未闭合 reservation 或仍被 CCC 引用的 Order 永不淘汰，且合法迟到事实窗口已结束、审计摘要已提交。
- [x] 墓碑创建和热表释放在同一持久 barrier 上提交；崩溃恢复不会同时丢失热 Order 与墓碑。
- [x] 超过当前玩具上限的长期订单轨迹、registry/gateway gate 容量和重启恢复有确定性压力验收；耗尽时明确 RecoveryOnly。

## Out of scope

- 无限内存、静默覆盖最旧订单或在没有测量前引入外部数据库框架。

## Answer

FoundTerminal / ConfirmedAbsent 在热 Order 上提交 `archive_audit_digest` 并关闭迟到事实窗口。compact 只淘汰窗口已关闭、reservation 已闭合、无 replacement、且不被热表 predecessor 引用的 filled/canceled/rejected 订单；digest 必须与提交值一致。Unknown / PendingCancel 继续阻断新发且不进入墓碑。无窗口的终态订单在容量压力下保持热表并进入 RecoveryOnly。snapshot schema 15。Debug `zig build test` 238/238。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R11-A](../review-repair-plan-2026-09-23.md#11墓碑身份)要求墓碑保存每张 Order 自身的 OrderIntentIdentity；多成员组的第二单及 CCC replacement 不能使用组首序号。补充压缩前后幂等、冲突、迟到报告、predecessor 和摘要验收。

## 2026-09-26 修复与验收

- `src/oms.zig` 的热 `Order` 保存自身 `intent_sequence`，place 使用成员序号，CCC replacement 使用原 amend 序号；组首序号只作为组身份。压缩墓碑从热单复制自身序号，归档摘要覆盖策略、意图、组、predecessor、ClientOrderId 与 Canonical report digest。
- 新增多成员组第二单压缩回归：墓碑为成员序号 8 而非组首 7；压缩后重复意图无副作用、冲突意图拒绝、迟到重复 report 为 no-op、迟到冲突锁存 RecoveryOnly。CCC successor 压缩回归：墓碑保留 amend 序号 2、组首 1 和 predecessor；篡改已归档资格的热单意图身份会因摘要不一致而拒绝压缩。
- 既有 OMS 长轨迹覆盖 8 个热单与 2 个墓碑后的 RecoveryOnly、无归档窗口和活跃/Unknown/PendingCancel/predecessor 不淘汰；registry、Gateway gate 容量测试及分片 snapshot/tail 恢复测试继续通过。热表释放与墓碑提交沿用 OMS 候选状态原子提交及分片持久 barrier。
- `src/production_contract.zig` 升至 acceptance/journal/state/registry 12/21/24/18，固定轨迹与四分片摘要按当前源码重新计算。`zig test src/main.zig -O Debug --stack 67108864` 和 `-O ReleaseSafe` 各 295/295；`zig fmt --check` 与 `git diff --check` 通过。仅为离线证据，Linux/Venue/生产资金资格保持 `not_run`；完整验收封存留 12 票。
