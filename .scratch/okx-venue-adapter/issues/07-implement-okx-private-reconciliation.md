# 接入 OKX 私有事实与启动重连对账

Type: task
Status: open
Assignee:
Blocked by: 01, 02, 03, 04, 05
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何通过 OKX Demo 私有 WebSocket 与 REST bootstrap/reconciliation 生成可去重的 ExecutionReport、Fill、ExchangeBalanceSnapshot、ExchangePositionSnapshot、ExchangeMarginSnapshot 和 VenueAccountConfigurationSnapshot，并在启动、断连、分页、迟到及冲突事实下只在完整解释后恢复新增风险？
