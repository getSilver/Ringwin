# 02: 让 Canonical Venue 对账推进 OMS

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (can start immediately)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让 Venue 返回的 OrderReconciliationResult 成为关闭 Unknown 和推进订单生命周期的唯一规范事实，并严格区分 FoundLive、FoundTerminal、ConfirmedAbsent 与 Unresolved？

## What to build

贯通一个真实 Venue 对账结果从 CanonicalEvent 到 OMS、SafetyGate、RiskReservation 和后续命令的完整路径。ConfirmedAbsent 只证明原发送未形成 Venue Order；任何证据不完整或字段冲突都保持 Unknown 并锁存 ReconciliationBreak。

## Acceptance criteria

- [x] Canonical 对账结果携带目标 Order、revision、累计/剩余数量、证据范围和适用规则版本，并能确定性映射到 OMS。
- [x] FoundLive 恢复精确 live/partially-filled 状态；FoundTerminal 根据权威终态区分 filled、canceled 或 rejected，不靠数量猜测终态类别。
- [x] ConfirmedAbsent 永远不能产生 filled、Fill 或成交账务；它只关闭对应未形成的发送尝试并按合同处置 reservation。
- [x] Unresolved 保持 Unknown、占用和 latched SafetyGate；重复事实为 no-op，同身份冲突失败关闭。
- [x] Venue canonical 路径与内部恢复路径不再维护两套对账语义；live/replay 的订单状态、占用、trace 和 digest 一致。

## Out of scope

- 改写各 Venue 的网络查询覆盖；真实查询资格仍由各 Venue production-readiness issue 验证。
