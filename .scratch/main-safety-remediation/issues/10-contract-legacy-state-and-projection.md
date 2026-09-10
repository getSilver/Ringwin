# 10: 删除竞争订单状态与废弃经济投影

Type: task
Status: resolved
Assignee: Codex
Blocked by: [09 把 legacy 订单与策略调用方迁入权威 OMS](09-migrate-legacy-order-and-strategy-paths.md)
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
