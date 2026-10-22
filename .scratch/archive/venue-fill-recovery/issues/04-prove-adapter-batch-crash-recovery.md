# 证明批次中断后的确定性恢复

Type: task
Status: resolved
Assignee:
Blocked by: [03 贯通 OKX 私有事实到权威状态](03-integrate-okx-private-facts-through-core.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

当 Adapter batch 逐条提交并在任一点失败或崩溃时，哪些持久事实足以恢复未完成工作，且如何保证
后续记录不丢失、经济事实不重复、外部风险不继续扩大？

## What to build

沿真实 Adapter-to-core 路径加入最小故障注入矩阵，证明 RawIngress、canonical 事实、权威提交和
snapshot 的既有持久化边界能够恢复整个 batch。失败后锁存 SafetyGate；恢复从持久 ingress 和已提交
身份继续，不把重试解释为新的 Fill，也不自动重发订单。

## Acceptance criteria

- [x] RawIngress 已提交后中断，重启能够重新解析并应用尚未提交的 canonical 事实。
- [x] report 提交后、Fill 提交前中断，重启只补齐 Fill，不重复推进订单或经济账。
- [x] Fill 提交前与提交后分别中断，恢复结果可区分且最终只记账一次。
- [x] Fill 已入账但余额事实尚未到达时保留待对账状态；重启不会伪造账户闭合。
- [x] DurableStore append、commit 和 snapshot 各自失败时保持最后可证明 barrier，并关闭相应 SafetyGate。
- [x] Trace、journal 或 identity evidence 容量耗尽发生在外部效果前，并且不会静默丢弃 batch 尾部。
- [x] adapter pending queue 能从持久事实重构或明确重新解析；进程内 queue 不是唯一恢复依据。
- [x] 任一失败后的 replay 不持有发送能力，`writes_sent=0`，且恢复 digest 与无故障执行一致。
- [x] 不把整个 batch 改造成新的全局原子事务；若现有持久 seam 确实不足，先以失败用例证明缺口。

## Out of scope

- 真实磁盘断电、目标 Linux 文件系统资格或线上网络故障注入。
- 自动重发 Unknown 或其他未能证明未生效的外部请求。

## Gap-to-acceptance plan

Build on 03's exact public batch fixture. Inject interruption after raw ingress, after report, before/after
Fill, before balance, and at DurableStore append/commit/snapshot. Each row must restart through Owner recovery,
reparse durable raw evidence where needed, compare the no-fault semantic result, keep SafetyGate closed on
storage failure, and assert replay has no send capability.

## Progress record

2026-09-22: the missing RawIngress prerequisite is now concrete. `raw_ingress.DurableSink` writes raw bytes,
SHA-256, session, clock metadata and private REST route to a `DurableStore.raw_ingress` stream before decoder
invocation, commits each record, and exposes only committed records for replay. Frames above one journal
payload reject fail-closed; no truncation or in-memory-only queue is recovery evidence. The remaining work is
to drive recovered bytes through a fresh adapter at the report/Fill/balance and store-fault crash points.

2026-09-22: added adapter-owned replay entry points. `replayPrivateWs` and `replayPrivateRest` accept only
the original durable evidence and invoke the existing Reconciler state machine without a second RawIngress
append. The offline fixture starts a fresh adapter, restores order links, replays the committed raw log via
those public entry points, and checks that the recovery sink received no duplicate writes. Crash-point and
append/commit/snapshot fault rows remain open.

2026-09-22: the first raw two-partial-fill fixture now commits its `execution_report`, drops the original
Owner, restores from the decision snapshot/tail, and applies only the retained canonical Fill. This proves
the report-before-Fill boundary does not repeat OMS progression and applies the unique Fill once. MemoryStore
now has a point-specific test hook; Owner tests cover append, commit and snapshot-publish faults, each with
the last proven barrier and a closed SafetyGate. Fill-after-commit, missing-balance, capacity and full
crash-point rows remain open.

2026-09-22: closed the remaining matrix with the public offline fixture. A fresh adapter reconstructs the
committed raw prefix and produces a byte-for-byte equal canonical Fill tail; the recovered Owner applies that
tail exactly once. The fixture then distinguishes the report-only and Fill-committed digests across restart.
`accountReconciliationPending()` derives the single-flight pending state from the durable control/result
trace, so a Fill followed by no new balance remains pending after Owner recovery and the restarted adapter
emits only a new reconciliation start, never a fabricated completion. Queue saturation accepts 45 two-fact
frames, rejects the 46th before RawIngress append, and drains all 90 retained facts. The replay adapters use
only replay entry points, keep their RawIngress sink at sequence 1, and the test asserts zero transport
attempts. `raw_ingress` now uses the frozen journal schema and the correct 72-byte header; its fault test and
the Owner append/commit/publish barrier test pass. No global batch transaction was added.
