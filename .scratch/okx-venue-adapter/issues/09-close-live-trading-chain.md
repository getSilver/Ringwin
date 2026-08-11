# 闭合 TradingShard 到 OKX Demo 的真实交易链

Type: task
Status: open
Assignee: Codex
Blocked by: 04, 05, 06, 07, 08
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何让固定测试策略产生的 OrderIntent 经现有规范化、定点风险、OrderCommand 和 OKX Adapter 到达 Demo Trading，再让真实回报闭合 Order、双层仓位、账本、费用、PnL、RawIngress、完整 EventEnvelope v1 四时间与 presence bits、稳定日志及重放摘要，且实时副作用永不在历史重放时再次发送？

## Progress

- `654874f` 已升级稳定日志为四时间与显式 presence bits，并加入 OKX Demo live side-effect boundary：replay/dry-run 无法调用 transport；Demo-live 必须同时满足显式授权、Demo endpoint/header、预检、稳定对账、无 Unknown、清理武装及 25 USDT 聚合上限；响应先提交 RawIngress 再分类。
- `4c8ba51` 已用可复现的 libcurl 8.21.0 静态 Schannel 构建通过 C ABI 版本/TLS/HTTPS/WSS 资格，并通过显式系统代理完成 OKX public HTTPS 200 探测。当前只读 Demo preflight 再次通过，未发送交易写请求。
- 尚未闭合：REST 签名 owner、private WSS/multi loop、固定策略到真实 Demo 回报的投影与重放摘要、失败关闭清理，以及经明确 `--demo-live` 授权后的会成交验收。因此本票保持 open。
