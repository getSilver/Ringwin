# 05: 贯通终态订单与发送证据归档

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何订单安全终态后完成归档提交和容量释放，再接收新订单；历史重试与崩溃恢复不会再次发送已接受命令？

## What to build

订单安全终态后完成归档提交和容量释放，再接收新订单；历史重试与崩溃恢复不会再次发送已接受命令。

## Acceptance criteria

- [ ] 联动 OMS 意图/命令/report/reconciliation、墓碑/predecessor 与 Gateway accepted/uncertain dispatch 历史，完成归档、身份查证、重复输入和恢复全链路。
- [ ] 活跃、Unknown、PendingCancel、未闭合 reservation、仍被引用或迟到事实窗口未满足合同的订单不得淘汰；FoundTerminal 不单独证明经济事实齐全。
- [ ] 历史重复无副作用，冲突锁存 ReconciliationBreak；查询超时、缺失或不可解释的旧事实失败关闭，不作为新事实接受。
- [ ] 归档身份、内容摘要和热状态释放形成可恢复提交协议；逐边界崩溃不能同时丢失热单和历史证据。
- [ ] 验收 CCC、多成员意图、迟到重复/冲突与归档失败；ClientOrderId、Order/Command 身份不复用，已接受与 Unknown 命令恢复后不自动重发。

## Evidence

2026-10-10：03及04已完成，本票开始本地实现。沿用已批准的公共
`VenueAdapter → Owner.applyAdapterBatch/apply → TradingShard → Store → snapshot/recover`
及 `Owner.send → Gateway → counting Adapter` 接缝，先验证缺失 Fill 不具备归档资格。
不以 Store 有序 segment 回执代替业务身份包含/非包含证明。
完成时填写当前源码身份、复现入口、实际结果和剩余范围。

## Out of scope

用户已授权本票本地实现；不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
