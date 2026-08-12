# 闭合多 Instrument SPOT 与永续 OMS 生命周期

Type: task
Status: open
Assignee:
Blocked by: 02
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何让同一 TradingShard 同时维护有界的多 Instrument、多 Order 生命周期，闭合 SPOT 与 isolated/net USDT 永续的 place/amend/cancel、IntentGroup、逐项 batch、CancelConfirmCreate、Unknown 和终态幂等，而不把 Venue 字段或 Adapter 调度带入核心？
