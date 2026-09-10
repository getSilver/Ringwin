# 05: 保留强平与未归属经济事实的危险语义

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (can start immediately)
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
