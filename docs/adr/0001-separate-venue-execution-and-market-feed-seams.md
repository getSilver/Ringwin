---
status: accepted
date: 2026-08-28
---

# 分离 Venue 执行与公共行情接缝

RingWin 的多交易所接入使用两个 seam：绑定 `Venue + Environment + ExchangeAccount` 的
`VenueAdapter` 负责订单、私有账户事实和对账；可跨账户共享的 `MarketFeedAdapter` 负责公共行情。
两者只输出核心 `CanonicalEvent`，Venue 私有协议和 decoder 事件保留在各自 implementation 与
RawIngress 中。这个选择避免把公共行情生命周期绑到账户连接，也阻止 OKX/Binance/Bybit 字段
进入 TradingShard、OMS、日志和重放。

## Considered Options

- 一个 Adapter 同时承载公共行情与账户执行：接口更少，但会混淆账户归属、连接复用和故障范围。
- 每家 Venue 直接接入核心：短期改动少，但会复制当前 OKX 直连路径并迫使核心按 Venue 分支。
- 通用 transport/plugin 框架：统一了变化最剧烈的协议细节，却没有增加核心领域语义的稳定性。

## Consequences

- Execution Gateway 按 `ExchangeAccountIdentity` 路由 VenueAdapter；公共行情按 Venue/订阅范围隔离。
- Adapter 私有事件跨 seam 前必须翻译，只有核心事件可以命名为 `CanonicalEvent`。
- 新 Venue 必须通过与 SimulatedVenue、OKX 相同的执行与行情契约测试。
- Smart Order Routing、动态插件和通用 REST/WS/auth 不属于该决定。
