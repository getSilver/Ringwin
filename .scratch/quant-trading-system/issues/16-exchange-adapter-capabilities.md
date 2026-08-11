# 建立交易所适配器能力契约

Type: research
Status: resolved
Blocked by: 13, 14
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

所选交易所在行情同步、客户端订单号、改单、批量请求、限流、回报序号、账户模式、对账和断线恢复方面分别提供什么保证，统一适配器应如何表达能力与降级？

## Answer

四家官方 API 均覆盖首版的普通现货和 USDT 线性永续；OKX、Binance 和 Bitget 文档确认目标基础订单范围，Gate.io USDT 永续 FOK 仍须测试环境确认。

统一适配器按 `Venue + product` 声明 L2 衔接、订单身份、改单类型、批量部分成功、限流及对账能力。客户端订单号一律不视为历史级幂等键，私有 WebSocket 一律不视为可重放事实日志；请求结果不明时进入 `Unknown`，断线后通过 REST 重建订单、成交、余额和仓位。未确认或未通过测试环境准入的能力 fail closed。

完整矩阵、官方证据、恢复合同及生产准入测试见[研究记录](../research/16-exchange-adapter-capabilities.md)。
