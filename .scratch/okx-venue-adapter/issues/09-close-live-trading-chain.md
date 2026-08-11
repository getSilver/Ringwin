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
- 2026-08-11 SystemOwner 明确授权 `--demo-live` 后：修复只读 private WSS 资格脚本的系统代理与无 `code/event/arg` 成功帧兼容，使用可达的 Demo private WSS 443 endpoint 完成登录、orders/account/positions 三频道 ACK 及 account/positions snapshot；随后执行约 5 USDT 的 `BTC-USDT` post-only place/cancel，写请求成功且最终预检再次证明零挂单、零仓位、零负债。该订单未成交，只证明认证写链与清理，不能替代尚缺的成交、费用、PnL 和重放闭环。
- Zig 产品路径现已增加定长凭证、显式清零、增量 HMAC-SHA256/Base64 与完整 Demo REST headers；`RestOwner` 在既有 libcurl/Schannel module 内实现 `okx_live_chain.Transport`，将发送前失败、完整响应与传输不确定映射为既定 outcome。真实 `GET /api/v5/account/config` 已经由该 Zig owner 签名并成功返回，`writes=0`；PowerShell 仅从被忽略的 env 文件注入进程环境并在结束时清除，不再代替产品签名。
- 同一 Zig `TransportOwner` 现已持有 REST easy 与 private WSS multi/easy handles：固定 Demo private endpoint、系统代理、严格 TLS、`CONNECT_ONLY=2`、完整 text message 重组、1 MiB 上限、单调读超时、atomic cancellation、`curl_multi_wakeup` 和 owner-thread remove/cleanup。真实 Demo 已通过登录、三频道 ACK、account/positions snapshot；9 个帧全部先写 RawIngress 再由统一 `Reconciler.ingestWsMessage` 路由，取消 fence 通过且 `writes=0`。
- SPOT 不能复用旧 fixture 只按 USDT 估算手续费的经济假设，故新增 `okx_spot_projection.zig` 闭合 BTC-USDT 原币经济投影。模块从既有 CanonicalEvent 接受已归属的 ExecutionReport、Fill 与余额 snapshot，以 1e-8 BTC/USDT 定点数同步更新 Portfolio/Exchange 双层余额、现货仓位、OpenCost、实际 TradingFee/TradingRebate、RealizedPnL 和账本事务；买入以 BTC 扣费的 fixture 已通过最终余额对账与确定性 digest 重放。当前公共规则仍为 SWAP `minSz=0.01 contract`、`ctVal=0.01 BTC`，所以 25 USDT gate 并不静态排除 SWAP，最终路径必须按运行时规则与价格选择。本票仍缺真实固定策略下单及运行后反向成交清理。
- 现货投影现已复用既有 CRC32C `journal.Journal`，为已归属的 OKX SPOT ExecutionReport、Fill 与完整余额 snapshot 固定 EventType `1001..1003` 和 StableEventSchema v1。codec 保留 EventEnvelope 四时间/presence、RawEvidenceRef、SourceFactIdentity、所有 Decimal presence 与 venue 字段；semantic replay 对未知 type/schema、非法 flags/time、非规范 Decimal、截断尾部和投影冲突失败关闭，并从稳定字节恢复相同经济 digest。通用日志 payload 上限仅从 256 提升至 2048 字节以容纳最多 8 行完整余额事实，既有记录 wire encoding 不变。
