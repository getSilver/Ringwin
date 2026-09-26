# 10: 删除竞争订单状态与废弃经济投影

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (09 已收口)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何证明所有调用方已经迁移，并彻底删除会与 OMS、版本化风险和统一经济投影竞争的兼容形态？

## What to build

完成 expand-contract 的 contract 阶段：删除 legacy 单订单状态、兼容 OrderCommand、固定杠杆风险账本、硬编码 timer 交易路径和未接入主构建图的竞争经济投影；保留边界所需的 Canonical、OMS 和 Venue 私有类型。

## Acceptance criteria

- [x] 源码不再包含第二套 order state、filled/quantity/reservation/risk lease 权威标量或固定 client order identity。
- [x] RiskLease 闭合只针对版本化 RiskReservation、仓位和 MarginRules，不再使用固定杠杆兼容计算。
- [x] 未被产品路径引用且竞争账本所有权的投影被删除；仍需保留的历史 fixture 明确隔离且不能进入主测试图。
- [x] 不合并 Canonical/Core/Host IPC 编码，也不把 Venue 私有 OrderCommand 泄漏进核心。
- [x] 全仓引用检查、格式检查和目标回归证明旧类型、旧字段与旧路径均无调用方。

## Out of scope

- 仅为缩短文件行数而机械拆分 TradingShard，或新增一层只转发调用的抽象。

## Answer

legacy 订单/风险标量和未使用的竞争经济投影已删除；保留的 Canonical/Core/Host IPC 边界没有新增转发抽象。

## 2026-09-23 复核与重开

本次未确认 10 有新增缺陷。09 重开后，10 的旧全仓引用与回归证据不再足以证明最终形态；待 09 完成后重新检查竞争订单、风险、经济权威和 raw 业务 send 未回流，才恢复 resolved。见[修复计划](../review-repair-plan-2026-09-23.md)。

## 2026-09-26 重新验收

以 `2c65fb6` 为检查起点，对当前工作树执行全仓引用核对。`TradingShard` 没有 `order_state`、`filled_quantity`、`order_quantity`、`open_order_reservation_micros`、`risk_lease_remaining_micros`、`layered_risk_reserved_micros`、`last_canonical_report`、`last_canonical_fill` 等旧权威字段；`trading_shard.OrderCommand` 仅为 `oms.Command` 别名。RiskLease 剩余从 OMS `activeReservations` 与经济投影的持仓保证金推导，`assertClosures` 用同一来源闭合，没有固定杠杆计算。timer 用分片策略身份与递增意图序号调用 `submitOrderIntent`。

业务订单路径由 `demo_authority.Owner.send` 取得持久 OMS command，再走 `ExecutionGateway.sendFromShard`；直接 Adapter 调用仅用于对账，`sendUnprovedForContractTest` 只在网关同文件测试中调用。`simulated_lifecycle_projection` 是当前 Demo/模拟验收的事实消费者与 replay 摘要，并非遗留 fixture；它不进入 `TradingShard`、RiskDecision 或发送准入，因此不构成第二账本所有者。Canonical、Core、Host IPC 与 Venue 私有命令继续各守边界。

`zig fmt --check` 覆盖上述核心与 Demo 文件；当前工作树的 `zig test src/main.zig -OReleaseSafe` 及 `zig test src/main.zig -ODebug --stack 67108864` 均为 294/294。此处是 10 票的离线回归，不封存脏工作树的完整源码身份；12 票仍负责最终封存，Linux、Venue 与生产资金资格仍为 `not_run`。
