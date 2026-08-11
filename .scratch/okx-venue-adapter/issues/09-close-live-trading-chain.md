# 闭合 TradingShard 到 OKX Demo 的真实交易链

Type: task
Status: resolved
Assignee: Codex
Blocked by: 04, 05, 06, 07, 08
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何让固定测试策略产生的 OrderIntent 经现有规范化、定点风险、OrderCommand 和 OKX Adapter 到达 Demo Trading，再让真实回报闭合 Order、双层仓位、账本、费用、PnL、RawIngress、完整 EventEnvelope v1 四时间与 presence bits、稳定日志及重放摘要，且实时副作用永不在历史重放时再次发送？

## Progress

- `654874f` 已升级稳定日志为四时间与显式 presence bits，并加入 OKX Demo live side-effect boundary：replay/dry-run 无法调用 transport；Demo-live 必须同时满足显式授权、Demo endpoint/header、预检、稳定对账、无 Unknown、清理武装及 25 USDT 聚合上限；响应先提交 RawIngress 再分类。
- `4c8ba51` 已用可复现的 libcurl 8.21.0 静态 Schannel 构建通过 C ABI 版本/TLS/HTTPS/WSS 资格，并通过显式系统代理完成 OKX public HTTPS 200 探测。当前只读 Demo preflight 再次通过，未发送交易写请求。
- 尚未闭合：固定策略到真实 Demo 回报的会成交验收与失败关闭清理。因此本票保持 open。
- 2026-08-11 SystemOwner 明确授权 `--demo-live` 后：修复只读 private WSS 资格脚本的系统代理与无 `code/event/arg` 成功帧兼容，使用可达的 Demo private WSS 443 endpoint 完成登录、orders/account/positions 三频道 ACK 及 account/positions snapshot；随后执行约 5 USDT 的 `BTC-USDT` post-only place/cancel，写请求成功且最终预检再次证明零挂单、零仓位、零负债。该订单未成交，只证明认证写链与清理，不能替代尚缺的成交、费用、PnL 和重放闭环。
- Zig 产品路径现已增加定长凭证、显式清零、增量 HMAC-SHA256/Base64 与完整 Demo REST headers；`RestOwner` 在既有 libcurl/Schannel module 内实现 `okx_live_chain.Transport`，将发送前失败、完整响应与传输不确定映射为既定 outcome。真实 `GET /api/v5/account/config` 已经由该 Zig owner 签名并成功返回，`writes=0`；PowerShell 仅从被忽略的 env 文件注入进程环境并在结束时清除，不再代替产品签名。
- 同一 Zig `TransportOwner` 现已持有 REST easy 与 private WSS multi/easy handles：固定 Demo private endpoint、系统代理、严格 TLS、`CONNECT_ONLY=2`、完整 text message 重组、1 MiB 上限、单调读超时、atomic cancellation、`curl_multi_wakeup` 和 owner-thread remove/cleanup。真实 Demo 已通过登录、三频道 ACK、account/positions snapshot；9 个帧全部先写 RawIngress 再由统一 `Reconciler.ingestWsMessage` 路由，取消 fence 通过且 `writes=0`。
- SPOT 不能复用旧 fixture 只按 USDT 估算手续费的经济假设，故新增 `okx_spot_projection.zig` 闭合 BTC-USDT 原币经济投影。模块从既有 CanonicalEvent 接受已归属的 ExecutionReport、Fill 与余额 snapshot，以 1e-8 BTC/USDT 定点数同步更新 Portfolio/Exchange 双层余额、现货仓位、OpenCost、实际 TradingFee/TradingRebate、RealizedPnL 和账本事务；买入以 BTC 扣费的 fixture 已通过最终余额对账与确定性 digest 重放。当前公共规则仍为 SWAP `minSz=0.01 contract`、`ctVal=0.01 BTC`，所以 25 USDT gate 并不静态排除 SWAP，最终路径必须按运行时规则与价格选择。本票仍缺真实固定策略下单及运行后反向成交清理。
- 现货投影现已复用既有 CRC32C `journal.Journal`，为已归属的 OKX SPOT ExecutionReport、Fill 与完整余额 snapshot 固定 EventType `1001..1003` 和 StableEventSchema v1。codec 保留 EventEnvelope 四时间/presence、RawEvidenceRef、SourceFactIdentity、所有 Decimal presence 与 venue 字段；semantic replay 对未知 type/schema、非法 flags/time、非规范 Decimal、截断尾部和投影冲突失败关闭，并从稳定字节恢复相同经济 digest。通用日志 payload 上限仅从 256 提升至 2048 字节以容纳最多 8 行完整余额事实，既有记录 wire encoding 不变。
- 现货投影已从单订单深化为固定容量的顺序订单集合，可同时保留固定策略买单与反向清理卖单，稳定摘要及 replay 覆盖全部订单。BTC-USDT 当前规则为 `lotSz=0.00000001`、`minSz=0.00001`；买入以 BTC 扣费时，投影同时减少原币余额、现货仓位及按成交价计量的成本基础，避免余额归零后残留手续费“幽灵仓位”。卖出以 BTC 扣费的未冻结语义失败关闭。买入净数量后全量卖出的测试现已闭合为零仓位、零 OpenCost，并通过确定性稳定重放。
- 2026-08-12 的两次早期 `NoSpaceLeft` 实际发生在发送前的 RFC3339 时间戳格式化；只读订单/成交历史确认当时没有 `RWN1` 订单。旧的“已成交但只在显示阶段失败”判断不成立，未把它作为验收证据。

## Answer

固定策略现通过真实产品 seam 完成 `OrderIntentV1 -> Gateway -> TradingShard cash risk -> QualifiedHostOrder -> OrderCommand -> OKX Adapter`，不再由验收程序手工伪造已授权策略订单。SPOT 风控显式使用 1e-8 数量分母和现金预留模型，买入预留现货名义金额及费用；Gateway 新增 IOC wire 值但继续校验 session、schema、activation、cursor 与新鲜度。重放只消费稳定事实，不持有 transport，无法再次发送副作用。

独立入口 `tools/run-okx-demo-live-acceptance.ps1` 提供 `-PrepareOnly`、显式 `-DemoLive` 和仅用于失败恢复的 `-CleanupOnly`。三者都先完成 Demo/global 资格、USDT/BTC 白名单、零挂单/衍生品仓位/负债、private WSS 三频道及九 REST 端点双读屏障；写模式只允许 ReleaseSafe。策略买价取 ticker 卖一与实时 `buyLmt` 的交集，清理保护价取买一与 `sellLmt` 的交集；没有可执行交集即失败关闭。固定数量为 `0.0002 BTC`，本次名义金额约 12.7 USDT，低于 25 USDT 上限。

真实 Demo 暴露并闭合了四项协议边界：account/positions 的 `snapshot` 是初始及定期分页而非一次性终态；REST order history 不生成历史 Fill，Fill 由 orders WSS 或 fills-history 拥有，`billId` 只丰富 `(instId, tradeId)` 并进行双向唯一性校验；交易所余额、费用和 PnL 在 1e-8 投影边界向零量化，USDT 端点对账仅容许由两端量化产生的 1 atom 区间而 BTC 仍逐 atom 相等；订单终态后必须继续消费到与当前经济投影一致的账户观察，旧账户消息不能提前确认清理。

最终 `--demo-live` 真实运行成功：

```text
phase=private_stream ok
phase=bootstrap ok
phase=baseline ok
phase=strategy_order_command ok
environment=demo strategy=fixed-btc-usdt-ioc orders=2 cleanup=closed position_atoms=0 open_cost_atoms=0 raw_ingress=45 stable_records=17 replay_digest=83cb9848a462af8e0fcc90b34fb3f7fced81177cc3b41aed96a2c73e34064abb
```

买单和按实际净 BTC 数量发送的反向清理单均取得逐项 `sCode=0` 与私有终态；Portfolio/Exchange 双层零仓位、零 OpenCost、最终余额量化区间、稳定日志封口和 replay digest 全部闭合。包装器 finally 再次证明零挂单、零衍生品仓位、零负债且 USDT-only 无 BTC 残余。43 项 ReleaseSafe 与 ReleaseFast 核心测试通过，`x86_64-linux-gnu` ReleaseSafe 交叉构建通过；凭证始终只来自被 Git 忽略的 `.env.local`，未进入源码、日志、票据或制品。
