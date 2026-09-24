# 05: 保留强平与未归属经济事实的危险语义

Type: task
Status: resolved
Assignee: Codex
Blocked by: None
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何保证强平距离为零和无法可靠归属的 VenueForcedExecution 不会被转换成安全值或任意 VirtualPortfolio 的经济事实？

## What to build

让 AccountCoordinator 在聚合和扇出时保留危险事实的原始语义：零距离立即收紧 MarginSafetyGate；无法唯一归属的强制成交进入 SuspenseAccount 并建立 ReconciliationBreak，直到权威分配事实到达。

## Acceptance criteria

- [x] liquidation distance 的零值始终表示已经到达风险阈值；只有输入不完整时才使用 Unknown。
- [x] Portfolio 与 Exchange 任一侧为零都触发最严格 MarginSafetyGate，聚合不得把它改成无穷远。
- [x] owner 缺失的 VenueForcedExecution 不投递给任意 shard，不改变任何既有 VirtualPortfolioPosition。
- [x] 未归属金额与仓位进入显式 SuspenseAccount/ReconciliationBreak，并由后续不可变 ForcedExecutionAllocation 关闭。
- [x] 多 VirtualPortfolio、方向相反仓位、部分可归属和重启恢复均保持守恒、确定性及 live/replay 等价。

## Out of scope

- 自动猜测强制成交归属或使用账户净仓比例替代权威贡献事实。

## Answer

零 liquidation distance、缺失事实和未归属强制成交均保留危险语义；SuspenseAccount 容量拒绝不改变摘要，不可变 ForcedExecutionAllocation 保持经济守恒。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R05-A/R05-B](../review-repair-plan-2026-09-23.md#05强制成交经济归属)要求补证：调用方给出单一 owner 不得直接入账；有界多组合切片须保存并守恒数量、PnL、费用、罚金与仓位；分配后交付进度可在其他账户事实插入或崩溃后确定性恢复，不重复入账。

## 2026-09-24 修复与复验

强制成交不信任调用方 owner，统一进入 SuspenseAccount 并关闭账户门；门在强平未结时不能由保证金观察单独打开。权威分配以最多四个切片守恒数量、仓位变化、已实现 PnL、费用和罚金；相反方向与部分分配保留精确剩余，分片再核验真实持仓与 PnL。来源事实保持不变，已完成分配进入有界身份归档，后续强平源和账户快照不覆盖其幂等记录。

CoordinationJournal 记录分配和逐切片确认；分片先提交，同一身份重试不重复计费，确认前核验分片经济事实。正式 AccountRecovery 允许且仅允许摘要快照匹配、分片尾部只含已知强平切片的崩溃窗口，恢复后须重发分片摘要；没有分片提交的确认被拒。Debug（Windows 64 MiB 测试栈）与 ReleaseSafe 均 283/283；四分片固定摘要、快照/尾部重放和异常漂移回归通过。协调器 snapshot schema 5、tail schema 2，分片 journal/state schema 17/20。此处为离线语义与稳定日志证据；目标 DurableStore 同步及 Linux/Venue/生产资格仍由生产资格票验证。
