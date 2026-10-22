# 01: 提交 AccountProjection 的失效事实

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让账户观察的序号 gap、语义冲突和容量耗尽既向调用者报告失败，又作为可重放的权威失效事实
持久收紧交易权限，而不破坏 TradingShard 对其他失败输入的原子不变合同？

## What to build

让所有账户观察都通过 TradingShard 的公开事件入口演进。观察失败必须留下 AccountProjection invalid
和对应 SafetyGate 锁存证据，阻止新增风险；精确重复仍为幂等 no-op。只有满足已定义完整性条件的账户
bootstrap 或 reconciliation 才能恢复投影，恢复投影也不能越过人工 TradingAuthorization。

## Blocked by

None (can start immediately).

## Acceptance

- [x] 经 TradingShard 施加账户序号 gap 后，公开快照同时证明 AccountProjection invalid、相应 SafetyGate
      已锁存且新增风险请求被拒绝。
- [x] 相同身份但内容冲突以及已见观察容量耗尽产生同样的持久失败结果，不会因 apply 返回失败而回滚失效状态。
- [x] 精确重复的账户观察不改变 CanonicalStateDigest，也不重复产生账务、风险或控制副作用。
- [x] 完整账户 bootstrap/reconciliation 按明确序号恢复投影；不完整或过期恢复输入继续 fail-closed。
- [x] live、全量 replay 和 snapshot-tail replay 在成功、gap、冲突和恢复轨迹上得到相同状态与摘要。

## Evidence

- `src/account_projection.zig` records typed failure reasons and preserves exact duplicates as no-ops.
- `TradingShard.apply` only commits an invalid projection when the current observation changes the failure state; a previously latched failure can no longer make an unrelated rejected event commit partial ingress or projection state.
- The account SafetyGate uses one stable identity, gate/trace failures are no longer swallowed, and `applyStable` keeps the failed-event fact group instead of rolling it back through `errdefer`.
- Public-seam regression covers gap persistence, later rejected-event atomicity, stable journal replay and equal `CanonicalStateDigest`.
- `zig test src/main.zig` passes Debug and ReleaseSafe 179/179; `zig fmt --check` passes.
