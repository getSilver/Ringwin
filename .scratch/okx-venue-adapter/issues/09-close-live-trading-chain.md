# 闭合 TradingShard 到 OKX Demo 的真实交易链

Type: task
Status: open
Assignee:
Blocked by: 04, 05, 06, 07, 08
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何让固定测试策略产生的 OrderIntent 经现有规范化、定点风险、OrderCommand 和 OKX Adapter 到达 Demo Trading，再让真实回报闭合 Order、双层仓位、账本、费用、PnL、RawIngress、完整 EventEnvelope v1 四时间与 presence bits、稳定日志及重放摘要，且实时副作用永不在历史重放时再次发送？
