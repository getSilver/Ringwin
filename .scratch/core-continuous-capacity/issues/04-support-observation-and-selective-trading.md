# 04: 贯通多交易对观察与选择性交易

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何约 500 个组合可以保持观察状态，只有选定子集产生订单，并在重启后保留正确的 Instrument、策略与账户归属？

## What to build

约 500 个组合可以保持观察状态，只有选定子集产生订单，并在重启后保留正确的 Instrument、策略与账户归属。

## Acceptance criteria

- [x] 从 MarketFeedAdapter/CanonicalEvent 到规则、行情投影、策略决策、OMS/Gateway 和恢复验证 500 个组合，覆盖 4 个 Venue 路由范围；未实现 Venue 使用明确的离线契约输入，不宣称线上支持。
- [x] 同名交易对跨 Venue/产品的身份不混淆；共享行情/规则不复制所有权，策略订单、仓位、风险与账户隔离正确。
- [x] 观察或已连接但无存活订单的组合不占存活订单槽位；行情、连接、规则、余额和对账容量独立记账。
- [x] 启停交易子集、行情缺口、恢复以及长时间零订单场景可重现；未交易组合不被默认授予发送权限。
- [x] 联动 Instrument、原生资产、市场/账户投影和所有序列化计数/长度限制；超配置组合数明确拒绝，不覆盖既有状态。

## Evidence

2026-10-10：本票完成，见 [04证据](../04-evidence.md)。业务源码
`9bf7650892c25255ffe20b6d5af7f4e005738897`，Debug/ReleaseSafe 各 461/461，
ReleaseSafe 构建、格式与差异检查通过。四个持续 Owner 实际覆盖 500 观察组合、
128 selected live 和检查点恢复；两个 Spec P1 已有 RED/回归修复。
最大编码快照 432,940B、Shard 布局 863,568B；测试栈 256MiB，不代表生产栈资格。
05–12 与千单、保留和平台容量尚未完成。

## Out of scope

用户已授权本票本地实现；不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
