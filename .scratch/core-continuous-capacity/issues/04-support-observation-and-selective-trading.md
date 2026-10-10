# 04: 贯通多交易对观察与选择性交易

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何约 500 个组合可以保持观察状态，只有选定子集产生订单，并在重启后保留正确的 Instrument、策略与账户归属？

## What to build

约 500 个组合可以保持观察状态，只有选定子集产生订单，并在重启后保留正确的 Instrument、策略与账户归属。

## Acceptance criteria

- [ ] 从 MarketFeedAdapter/CanonicalEvent 到规则、行情投影、策略决策、OMS/Gateway 和恢复验证 500 个组合，覆盖 4 个 Venue 路由范围；未实现 Venue 使用明确的离线契约输入，不宣称线上支持。
- [ ] 同名交易对跨 Venue/产品的身份不混淆；共享行情/规则不复制所有权，策略订单、仓位、风险与账户隔离正确。
- [ ] 观察或已连接但无存活订单的组合不占存活订单槽位；行情、连接、规则、余额和对账容量独立记账。
- [ ] 启停交易子集、行情缺口、恢复以及长时间零订单场景可重现；未交易组合不被默认授予发送权限。
- [ ] 联动 Instrument、原生资产、市场/账户投影和所有序列化计数/长度限制；超配置组合数明确拒绝，不覆盖既有状态。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

用户已授权本票本地实现；不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
