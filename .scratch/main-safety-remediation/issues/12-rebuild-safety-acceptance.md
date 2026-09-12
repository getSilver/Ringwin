# 12: 重建 main 安全与权威状态验收基线

Type: task
Status: blocked
Assignee: Codex
Blocked by: [01 使极值算术与缺失输入失败关闭](01-fail-closed-arithmetic-and-inputs.md), [02 让 Canonical Venue 对账推进 OMS](02-apply-canonical-reconciliation-to-oms.md), [03 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](03-enforce-oms-intent-idempotency.md), [04 按权威剩余数量维护 RiskReservation](04-rebalance-reservation-from-authoritative-remaining.md), [05 保留强平与未归属经济事实的危险语义](05-preserve-dangerous-account-facts.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md), [07 以唯一 Gateway 强制真实 ReduceOnly 与 fencing](07-enforce-authoritative-gateway-send.md), [08 以 HostActivated 和只读 IPC 强制策略隔离](08-enforce-host-activation-and-ipc-isolation.md), [09 把 legacy 订单与策略调用方迁入权威 OMS](09-migrate-legacy-order-and-strategy-paths.md), [10 删除竞争订单状态与废弃经济投影](10-contract-legacy-state-and-projection.md), [11 实现可重放的订单容量与终态墓碑](11-manage-order-capacity-with-tombstones.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何以不可挑选、可重复的自动证据证明本次审查确认的缺口已经关闭，而不是再次用旧的 resolved 状态或普通 happy-path 回归代替验收？

## What to build

建立一条失败即停的安全验收波次，同时运行 Debug 与 ReleaseSafe 的成功、极值、冲突、Unknown、恢复、Host 故障、容量和 live/replay 轨迹。输出固定 schema、测试数、barrier、digest、发送计数及每项安全断言，并更新当前审查与 tracker 状态。

## Acceptance criteria

- [x] 自动检查逐项覆盖审查中的 H1、H2、M1、M3、M5 以及 15 项业务逻辑缺口；M2/M4/M6/M7 的生产接线状态明确引用 production-readiness 证据。
- [x] Debug 与 ReleaseSafe 使用相同输入矩阵，全部通过；极值输入返回稳定错误，没有 trap、回绕、状态提交或外部发送。
- [ ] Canonical 对账、部分成交、CCC、重复/冲突 Intent、真实 ReduceOnly、fencing、HostActivated、Suspense 和墓碑恢复均有 live/replay 等价证据，包括 06/07/11 的最终发送与归档不变量。
- [x] 验收报告固定记录 schema、源码 revision、精确 Zig、测试数、barrier、CanonicalStateDigest、Gateway send count 和失败事实，不能由调用方自报 passed。
- [x] 源码扫描证明 legacy 状态、raw 业务 send、固定 timer 身份和竞争经济投影已经删除。
- [x] 当前审查文档、模块 map、Frontier 和生产资格 blocker 与实际证据同步；未执行的 Linux/Venue/真实资金资格继续为 not_run。

## Out of scope

- 以本地 Windows 或 WSL 结果宣称目标 Linux、Testnet、ProductionQualified 或 Canary 已完成。

## Answer

当前离线脚本已固定 schema、revision、Zig、测试数、barrier、digest 与 send count；待 06/07/11 补齐后重封存，Linux/Venue/生产资格继续标记 not_run。
