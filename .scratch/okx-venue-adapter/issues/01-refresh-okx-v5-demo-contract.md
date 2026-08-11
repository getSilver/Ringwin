# 刷新 OKX API v5 与 Demo Trading 契约

Type: research
Status: open
Assignee: Codex research/okx-v5-demo
Blocked by:
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

截至当前日期，OKX 官方 API v5 对 BTC-USDT SPOT 与 BTC-USDT-SWAP Demo Trading 的 endpoint、认证和时间同步、InstrumentRules、L2 snapshot/delta 连续性、mark/index/funding、私有 orders/account/positions、全部既定订单能力、批量逐项结果、限流、错误分类、分页与 Unknown 对账分别提供什么可实现保证，Demo 与生产有哪些必须版本化记录的差异？

研究只使用 OKX 官方文档、公告和第一方接口；结论写入 [`research/01-okx-v5-demo-contract.md`](../research/01-okx-v5-demo-contract.md)。
