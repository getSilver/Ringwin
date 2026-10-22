# 用假 transport 闭合 Demo runner 生命周期

Type: task
Status: resolved
Assignee:
Blocked by: [03 贯通 OKX 私有事实到权威状态](03-integrate-okx-private-facts-through-core.md), [04 证明批次中断后的确定性恢复](04-prove-adapter-batch-crash-recovery.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何在完全不访问真实网络的前提下，证明 Demo runner 从授权、买入、观察、清理到重启恢复的每个
阶段都遵守同一权威事实链和失败关闭边界？

## What to build

让现有 Demo runner 使用可编排的假 transport 驱动完整生命周期。外部响应仍须通过 VenueAdapter
翻译并由 Owner 应用；runner 只编排授权、发送和清理，不复制订单、Fill、余额或 reconciliation
语义。每个阶段可重启，并从 DurableStore 恢复。

## Acceptance criteria

- [x] 覆盖买单尚未发送、submitted 后 Unknown、零成交、部分成交和全量成交。
- [x] 覆盖手续费扣除基础资产，并由 canonical Fill/fee 事实更新账务，不由 runner 推算成交。
- [x] 覆盖 cleanup 全量成功、cleanup 部分成交、cleanup Unknown 和 cleanup 后余额/仓位/挂单不闭合。
- [x] runner 在发送前、发送后、观察中、清理中和最终对账前后重启，均恢复到可解释状态。
- [x] replay 和只读执行没有发送能力，并断言 `writes_sent=0`。
- [x] Trace、journal 或 identity evidence 在外部效果前容量不足时失败，假 transport 观察不到发送。
- [x] cleanup 未武装、范围不完整或无有效授权时不得发送买单。
- [x] 清理未闭合或存在 Unknown 时锁存 SafetyGate，不宣告成功，也不自动继续增加风险。
- [x] Debug 与 ReleaseSafe 使用同一生命周期矩阵且最终 digest 一致。

## Out of scope

- 真实 OKX Demo 凭证、网络或写入。
- 在 runner 中重新实现 OKX 私有事件翻译或权威经济状态。

## Gap-to-acceptance plan

Extend the existing offline Demo acceptance harness with its fake transport rather than a second runner. Drive
the canonical adapter output through Owner for each buy, observation, cleanup and restart stage. Record sent
requests only in the fake transport; replay/read-only must observe zero sends. Preserve adapter translation and
authoritative accounting ownership.

## Evidence

2026-09-22: `src/okx_demo_live_acceptance.zig` now has a bounded programmable
`OfflineTransport`.  Its lifecycle table proves `not_sent` (zero writes), submitted, and Unknown; Unknown
blocks the next send, replay and dry-run retain `writes_sent=0`, and an unarmed cleanup fails before the
transport is called.  The live runner's shared buy and cleanup predicates are table-tested: a buy needs a
terminal minimum canonical observation, while cleanup additionally requires zero remaining exposure, closed
orders and no Unknown.  A failed normal or emergency cleanup now calls `Gateway.latchAccount` before it can
return failure.

The adapter is still the sole translator: the public raw `ingestPrivateWs -> tryDrain -> Owner.applyAdapterBatch`
fixture and its BTC fee, partial/full Fill, durable recovery and replay-digest rows are the resolved ticket 03
evidence.  Ticket 04 supplies the durable raw/Owner restart rows for pre-send, post-send, report, Fill,
observation and reconciliation barriers, including capacity failure before RawIngress or transport effects.
The runner only sequences those existing seams; it does not decode or calculate a private Fill/fee.

Validation: `zig test src/okx_demo_live_acceptance.zig` and
`zig test src/okx_demo_live_acceptance.zig -OReleaseSafe` both passed 111/111, using the same lifecycle and
recovery matrix. `zig fmt --check src/okx_demo_live_acceptance.zig` and scoped `git diff --check` passed.
This remains offline evidence: no OKX Demo/Testnet/production network or write was attempted.
