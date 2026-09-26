# 09: 把 legacy 订单与策略调用方迁入权威 OMS

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (04、06、08 已收口)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何在持续保持回归可运行的前提下，把 timer、原生策略、Python StrategyHost、Canonical Venue 事实、快照和 replay 全部迁到同一 OMS/风险/经济权威状态？

## What to build

分批迁移所有仍读取或写入 legacy 单订单标量的调用方。原生与 Python OrderIntent 接受相同身份、side、OrderType、TIF、ReduceOnly、授权和拒绝原因；Canonical report/fill/reconciliation 只推进 OMS 导出的订单与经济状态。

## Acceptance criteria

- [x] 原生 timer 不再硬编码固定买单、IntentSequence 或 ClientOrderId；真实策略身份从持久 StrategyPrivateState 推进。
- [x] Python Host 能表达并通过同一 seam 处理 buy、sell、PortfolioReduceOnly 和生命周期 DeRisk 所需的合法意图。
- [x] 未授权、市场 gap、五层限额、opening gate、身份冲突和能力缺失产生各自准确且稳定的 CanonicalRejectReason。
- [x] Canonical execution/fill/reconciliation 不再双写 legacy 标量；所有查询、协调与摘要从 OMS/风险/经济深模块取得。
- [x] snapshot、restore、semantic replay、fixture 和 acceptance 全部迁到新权威形态，迁移批次之间持续通过目标测试。

## Out of scope

- 新策略算法、信号质量或 Python 高频交易支持。

## Answer

Canonical report/fill/reconciliation 不再镜像 `last_canonical_report`、`last_canonical_fill` 或 `layered_risk_reserved_micros`。报告身份与 `canonical_digest` 由 OMS `report_history` 拥有；成交身份由经济投影 `canonical_fill_evidence` 拥有，且在核对 OMS 剩余数量之前判定重复/冲突。风险剩余、协调摘要和 Host ingress 摘要从 `oms.activeReservations` 与经济投影派生。snapshot/replay schema 14。Debug `zig build test` 234/234。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R09-A](../review-repair-plan-2026-09-23.md#09稳定拒绝事实)要求通过真实 `submitOrderIntent`/`applyStable` 入口生成身份冲突、能力缺失、未激活及已有 open Order 等稳定拒绝事实，并与既有市场/risk 拒绝区分；不能只抛错、也不能产生订单或发送。

## 2026-09-26 R09-A 收口

`submitOrderIntent` 与直接 OMS group 在普通资格拒绝时写入携带具体原因的稳定事实，并在 OMS 身份历史占用原始意图；Python 请求的 cursor、配置、激活和账户身份纳入原始指纹。相同内容重试无操作，修改身份字段产生冲突事实，均不产生订单或发送。单条拒绝的原因写入 journal 首记录并经 replay 校验；身份容量耗尽以可重放事实进入 RecoveryOnly。快照容量随权威 trace 扩展到 64 KiB，固定轨迹与四分片摘要重封存。Debug 使用 Windows 64 MiB 测试栈，ReleaseSafe 使用默认栈；两者各 294/294，仅为离线证据。Linux、Venue 与生产资金资格保持 `not_run`。
