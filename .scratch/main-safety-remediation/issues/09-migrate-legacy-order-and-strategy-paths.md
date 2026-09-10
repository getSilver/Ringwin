# 09: 把 legacy 订单与策略调用方迁入权威 OMS

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](03-enforce-oms-intent-idempotency.md), [04 按权威剩余数量维护 RiskReservation](04-rebalance-reservation-from-authoritative-remaining.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md), [08 以 HostActivated 和只读 IPC 强制策略隔离](08-enforce-host-activation-and-ipc-isolation.md)
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
