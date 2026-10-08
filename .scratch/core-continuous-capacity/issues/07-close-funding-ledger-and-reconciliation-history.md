# 07: 贯通资金费、账本与对账历史归档

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [06 贯通成交与费用历史归档](06-close-fill-and-fee-archive.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何长期持仓跨多次资金费结算和对账继续运行，账本明细回收不丢失成本、PnL 或未解决差异？

## What to build

长期持仓跨多次资金费结算和对账继续运行，账本明细回收不丢失成本、PnL 或未解决差异。

## Acceptance criteria

- [ ] 贯通资金费/结算、对账和账本历史的归档与恢复，保留当前经济状态及历史身份链。
- [ ] 未解决 Suspense/ReconciliationBreak、待解释资金变化或仍需证据的事实不通过归档消失；重复 no-op，冲突失败关闭。
- [ ] 归档前后 Portfolio/Exchange 余额、仓位、保证金、成本、Realized/UnrealizedPnL 及账本借贷守恒。
- [ ] 验证跨多个结算周期、零订单但有持仓、混合资产费用与对账差异；不将测试输入解释为 Venue 协议资格。
- [ ] 在归档/检查点/恢复边界注入故障，重放得到一致经济状态，不重复结算或发送。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
