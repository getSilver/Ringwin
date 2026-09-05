# 02: 统一市场连续性与恢复权威

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让 MarketProjection、TradingShard 和 Execution Gateway 对行情 gap、健康状态和恢复使用同一权威
规则，使任何旁路健康通知或容量耗尽都不能重新开放风险？

## What to build

建立一条从 MarketFeedAdapter 的规范行情事实到 MarketProjection 和 SafetyGate 的连续性路径。delta gap
立即关闭相关 Instrument 的新增风险；普通 healthy 事实不能恢复；只有完整且新鲜的 L2 snapshot 能原子
恢复投影和对应 SelfRecoveringGate。超过有界 Instrument 跟踪容量时必须拒绝或锁存，不能静默忽略。

## Blocked by

None (can start immediately).

## Acceptance

- [x] 行情 delta gap 经公开 apply 路径后同时使 MarketProjection unhealthy 并关闭相关 OpeningGate。
- [x] gap 后注入独立 healthy 事实不能重新开门，仍然拒绝新增风险。
- [x] 完整、新鲜且序号有效的 L2 snapshot 原子恢复投影和 SelfRecoveringGate；陈旧或不完整快照不能恢复。
- [x] 超过 Instrument 跟踪容量时 fail-closed，未被记录的第五个或后续 Instrument 不会绕过保护。
- [x] 多 Instrument 交错 gap/恢复以及 live/replay 产生相同 gate 状态和 CanonicalStateDigest。

## Evidence

- `src/market_projection.zig` rejects stale/incomplete/scope-mismatched books and only complete fresh snapshots clear the projection failure.
- Market state is now isolated in four bounded per-Instrument projections; observing candidate rules preserves the active book, while activating a new rules version requires a fresh snapshot and price.
- `TradingShard` closes the self-recovering market gate on delta/health gaps; healthy notifications and deltas cannot reopen it.
- `src/execution_gateway.zig` fail-closes untracked instruments after bounded gate capacity is exhausted.
- `zig test src/main.zig -O Debug` and `-O ReleaseSafe`: 180/180 passed; market projection, simulated feed, canonical seam and gateway tests included.
