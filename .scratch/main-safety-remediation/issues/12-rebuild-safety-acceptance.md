# 12: 重建 main 安全与权威状态验收基线

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 使极值算术与缺失输入失败关闭](01-fail-closed-arithmetic-and-inputs.md), [02 让 Canonical Venue 对账推进 OMS](02-apply-canonical-reconciliation-to-oms.md), [03 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](03-enforce-oms-intent-idempotency.md), [04 按权威剩余数量维护 RiskReservation](04-rebalance-reservation-from-authoritative-remaining.md), [05 保留强平与未归属经济事实的危险语义](05-preserve-dangerous-account-facts.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md), [07 以唯一 Gateway 强制真实 ReduceOnly 与 fencing](07-enforce-authoritative-gateway-send.md), [08 以 HostActivated 和只读 IPC 强制策略隔离](08-enforce-host-activation-and-ipc-isolation.md), [09 把 legacy 订单与策略调用方迁入权威 OMS](09-migrate-legacy-order-and-strategy-paths.md), [10 删除竞争订单状态与废弃经济投影](10-contract-legacy-state-and-projection.md), [11 实现可重放的订单容量与终态墓碑](11-manage-order-capacity-with-tombstones.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何以不可挑选、可重复的自动证据证明本次审查确认的缺口已经关闭，而不是再次用旧的 resolved 状态或普通 happy-path 回归代替验收？

## What to build

建立一条失败即停的安全验收波次，同时运行 Debug 与 ReleaseSafe 的成功、极值、冲突、Unknown、恢复、Host 故障、容量和 live/replay 轨迹。输出固定 schema、测试数、barrier、digest、发送计数及每项安全断言，并更新当前审查与 tracker 状态。

## Acceptance criteria

- [x] 自动检查逐项覆盖审查中的 H1、H2、M1、M3、M5 以及 15 项业务逻辑缺口；M2/M4/M6/M7 的生产接线状态明确引用 production-readiness 证据，并覆盖 2026-09-23 复核缺口。
- [x] Debug 与 ReleaseSafe 使用相同输入矩阵，全部通过；极值输入返回稳定错误，没有 trap、回绕、状态提交或外部发送。
- [x] Canonical 对账、部分成交、CCC、重复/冲突 Intent、真实 ReduceOnly、fencing、HostActivated、Suspense 和墓碑恢复均有 live/replay 等价证据，包括 06/07/11 的最终发送与归档不变量。
- [x] 验收报告固定记录 schema、实际被测源码身份、精确 Zig、测试数、barrier、CanonicalStateDigest、Gateway send count 和失败事实；脏工作树不得仅以 `HEAD` 冒充被测内容，也不能由调用方自报 passed。
- [x] 源码扫描证明 legacy 状态、raw 业务 send、固定 timer 身份和竞争经济投影已经删除，且旧 schema 不自动获得发送能力。
- [x] 当前审查文档、模块 map、Frontier 和生产资格 blocker 与实际证据同步；未执行的 Linux/Venue/真实资金资格继续为 not_run。

## Out of scope

- 以本地 Windows 或 WSL 结果宣称目标 Linux、Testnet、ProductionQualified 或 Canary 已完成。

## Answer

`tools/verify-core-wave.ps1` 以同一输入矩阵跑完 Debug 与 ReleaseSafe 239/239，并强制读取 CCC、Intent 冲突、Suspense、墓碑归档恢复、HostActivated、持久 dispatch、replay 无发送和真实 ReduceOnly/fencing 的机器可读证据。journal/state schema 14/15，acceptance schema 7，report schema 3。Linux 仅为 compile_only；OKX Demo/Binance/Bybit Testnet 与 production_qualification 继续 not_run/false。

## 2026-09-23 复核与重开

上述 239/239 与 state schema 15 是历史记录，不能证明当前源码。本轮 [修复计划 R12-A/R12-B](../review-repair-plan-2026-09-23.md#0110-和-12回归与重新封存)要求报告绑定实际被测源码内容；脏工作树只记 `HEAD` 不合格。当前源码已使用 state schema 16；所有 01–11 缺口完成后才重跑 Debug/ReleaseSafe 并同步地图及资格状态。

## 2026-09-27 离线重新封存

机器报告：[evidence-2026-09-27.json](../evidence-2026-09-27.json)。`tools/verify-core-wave.ps1` 失败即停，检查 H1/H2/M1/M3/M5、15 项业务缺口、R07/R11 与旧 schema，运行同一 Debug/ReleaseSafe 输入矩阵；针对产品模型、L2 数量和 Fill 手续费，新增加真实分片入口的稳定拒绝及状态摘要不变断言。

- 报告 schema 4；acceptance/journal/state schema `13/22/25`；Zig `0.17.0-dev.315+5b647b792`；Debug/ReleaseSafe 各 `297/297`。
- 被测基准 `b4aead474503e15dbf87694e84d4078da6fe4535`，源码树 SHA-256 `6bb27f1caff605f7db98e0b7ad3d0358b37a568d7e3fe1e31f7513924f72b2e5`。摘要覆盖工作树中已跟踪及未跟踪的 `src/`、`python/`、`tools/` 和根 build 文件；报告明确 `source_dirty=true`，脚本在验收前后重算，不能把 HEAD 单独当作源码身份。未跟踪的 Windows 验证运行时需两处 Host activation 字段兼容调整才能编译离线主入口，仍留在用户工作树中。
- 四分片 barrier `25/31/24/24`，协调器 barrier `17`；协调器 digest `560321d6a22d0e2a67f2fadf52d718ff156cbee76a7fee7718bdd5b4ea4f964d`，共享摘要 `c1ed3c16215085079daf60a286e7b40e5936be6486371e243ba313e8a1dba6b3`。单分片 5 条轨迹、四分片 3 条恢复路径均与 replay 等价；Gateway adapter submissions `5`、owned commands `4`、replay_send_capability `false`。
- Python Host 5 个容量/故障场景通过；Simulated/OKX/Binance/Bybit 仅离线契约；Linux `compile_only`。OKX Demo、Binance/Bybit Testnet 均 `not_run`，production_qualification=`false`。本票未执行 Venue 或资金写入。
- M2 继续由[生产进程链](../../production-readiness/issues/02-run-linux-production-process-chain.md)、[Web 生命周期](../../production-readiness/issues/08-operate-and-deploy-signed-release.md)、[NodeFence](../../production-readiness/issues/10-fail-over-with-lease-and-node-fence.md)跟踪；M4 由 Web 生命周期跟踪；M6/M7 由[凭证准入](../../production-readiness/issues/04-unlock-credential-and-pass-security-admission.md)和[OKX Linux 在线链](../../production-readiness/issues/05-qualify-okx-linux-online-chain.md)跟踪。离线基线不能代替这些目标资格。
