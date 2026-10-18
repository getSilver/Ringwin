# 封存本地放行证据

Type: task
Status: resolved
Assignee:
Blocked by: [07 把成交恢复合同推广到所有 VenueAdapter](07-extend-fill-recovery-contract-to-all-venues.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何把本波全部修复固定为可重复、失败即停且不越权升级在线资格的本地放行证据？

## What to build

复用现有验收入口，把成交语义、OKX 公共 seam、批次恢复、Reconciler、Demo runner、顺序排列和
共享 Venue 合同组合成一个固定证据波次。记录精确 revision、schema、测试数、digest、发送计数和
失败事实，并把摘要追加到现有 OKX Linux 资格票，但不关闭该票。

## Acceptance criteria

- [x] 每个已知在线失败都有脱敏 fixture 和一条可说明先红后绿的固定回归。
- [x] 真实 `ingestPrivateWs → tryDrain → applyAdapterBatch` 集成、顺序排列及多笔部分成交全部通过。
- [x] crash/recovery 矩阵的 live/replay digest 完全一致，所有 replay 和只读路径 `writes_sent=0`。
- [x] 假 transport Demo runner 完成买入、费用、清理和任意阶段重启闭环；失败场景保持 SafetyGate 锁存。
- [x] Debug 与 ReleaseSafe 使用同一矩阵连续三轮结果一致，并固定测试数、schema、barrier 和 digest。
- [x] Linux ReleaseSafe 工件完成无网络离线验收，不访问凭证或 Venue endpoint。
- [x] 源码格式检查与 diff whitespace 检查通过。
- [x] 独立代码复审确认状态所有权、schema、持久化边界和失败关闭语义，并记录未解决问题。
- [x] 本地证据追加到现有 OKX Linux 资格票，但该票保持开放，ProductionQualified 不变。
- [x] 验收输出明确声明本票不授权 Demo、Testnet 或生产写入；下一次线上方案须另获 SystemOwner 授权。

## Out of scope

- 线上复验、真实资金操作、自动清理或关闭 production-readiness 票。
- 用单次通过、测试数量或本地 Linux 工件替代目标节点及在线资格。

## Review record

2026-09-22 scoped independent review found and this wave corrected two adapter safety defects:
canonical client IDs must remain authoritative across recovered order links, and a ready private fact must
remain queued until translation succeeds. A translation failure now latches adapter send backpressure and
`stop` rejects pending private/reconciliation facts.

The review also found that 03–07 still lack their required end-to-end fixture, crash/recovery, runner,
permutation, and cross-venue matrices. This ticket remains open: the current 254-test root run, formatting,
and whitespace checks are local evidence only and do not close those gaps or authorize online writes.

## Gap-to-acceptance plan

Run the completed shared matrix three times in Debug and ReleaseSafe, run the no-network Linux ReleaseSafe
artifact, and emit revision/schema/test-count/barrier/digest/writes-sent evidence. Append only that local
evidence to the existing OKX Linux qualification ticket; leave its status and all online qualifications open.

## Evidence

2026-09-23: [machine-readable local evidence](../evidence/2026-09-23-local-release-gate.json) records base revision `0d71e8e3cdd66d05303e0dd98e8c2e51f37eb690` with a dirty worktree, schema 7, journal schema 14 and state schema 16. Final Debug and ReleaseSafe root matrices each passed three consecutive `264/264` runs. Linux `x86_64-linux-gnu` ReleaseSafe `--test-no-exec` compiled successfully without executing or using network/credentials. The offline verifier recorded single-shard barrier 39/digest `e4ef5fb0fde1fa740cf59cb726130038bf755fb16505c81d01d43ceefe04fa40`, four-shard barriers 25/31/24/24, coordinator barrier 17/digest `3702f1e705efe44b6d315d6205fa56c067648a02c2fa3d64707d63cf3115060f`, and replay-send capability false.

The independent standards review found no scoped defect. The spec-review concern about stopping with ready private facts was rechecked and made explicit by a regression: `stop()` returns `OutputPending` until the ready private queue drains. No local code issue remains. These are offline-only results: no Demo, Testnet or production write was authorized or executed; all online qualifications remain unchanged and a future online test needs fresh SystemOwner authorization.
