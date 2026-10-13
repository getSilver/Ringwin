# 05: 贯通终态订单与发送证据归档

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何订单安全终态后完成归档提交和容量释放，再接收新订单；历史重试与崩溃恢复不会再次发送已接受命令？

## What to build

订单安全终态后完成归档提交和容量释放，再接收新订单；历史重试与崩溃恢复不会再次发送已接受命令。

## Acceptance criteria

- [x] 联动 OMS 意图/命令/report/reconciliation、墓碑/predecessor 与 Gateway accepted/uncertain dispatch 历史，完成归档、身份查证、重复输入和恢复全链路。
- [x] 活跃、Unknown、PendingCancel、未闭合 reservation、仍被引用或迟到事实窗口未满足合同的订单不得淘汰；FoundTerminal 不单独证明经济事实齐全。
- [x] 历史重复无副作用，冲突锁存 ReconciliationBreak；查询超时、缺失或不可解释的旧事实失败关闭，不作为新事实接受。
- [x] 归档身份、内容摘要和热状态释放形成可恢复提交协议；逐边界崩溃不能同时丢失热单和历史证据。
- [x] 验收 CCC、多成员意图、迟到重复/冲突与归档失败；ClientOrderId、Order/Command 身份不复用，已接受与 Unknown 命令恢复后不自动重发。

## Answer

2026-10-13按用户最新指令完成小规模功能验收：四分片各25 live/25 terminal、十轮各5单归档替换及最终Owner/Gateway恢复。生产容量常量未改，不再执行千单或容量压力。

冻结源码`85c00368e0bce74b876a6934864911bb810094992434e29e95da7536d975f999`，Debug/ReleaseSafe完整功能套件各538/538、退出0，串行执行；应用/CLI重建、五golden fixture及纯离线五角色链均退出0。Standards/Spec未确认具体P1/P2。

责任保持OMS判定资格，Owner发布历史并持久提交Core，再持久回收Gateway；认证冷历史、原候选时钟、延期admission、引用pin、前驱补交、身份高水位与accepted/Unknown零重发均有实际回归。共享journal/history配额修复通过完整两模式。

完整命令、逐项映射、实际产物/源码身份与旧失败/用户停止日志见[最终证据](../05-evidence.md)，审查见[优化审查](../05-optimization-review.md)。旧大负载中断不冒充完整通过。

## Out of scope

06–12及资源/RSS/索引成本、Windows/Linux平台生产资格未由本票取得。没有部署、真实Demo/Testnet/生产下单。执行预算按[地图当前规则](../map.md)与用户小规模功能要求推进。
