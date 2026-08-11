# OKX API v5 与 Demo Trading 契约刷新

研究日期：2026-08-11（UTC）
范围：`BTC-USDT` SPOT、`BTC-USDT-SWAP` 逐仓单向永续；只使用 OKX 官方文档、公告与公开 API。

## 结论

OKX API v5 足以实现本地图要求的 Demo 纵向闭环，但 Adapter 不能把 REST/WS 接收确认当成订单终态，也不能把私有 Orders WS 当成启动快照。正确合同是：`clOrdId`/`reqId` 关联请求，Orders WS 驱动增量，REST pending/order/history/fills/account/positions 在启动、重连和任何传输不确定时收敛事实；L2 使用 snapshot + delta，并只用 `seqId/prevSeqId` 判连续性。

Demo 与生产共享 REST API 路径和主要 schema，但使用不同 API key、WS 主机和 Demo 请求标志，且功能、流动性、撮合行为与变更发布时间可能不同。endpoint 必须按账户所属 OKX 实体配置，不能把任一地区文档中的主机名写成全球常量。[官方 API v5 总览](https://www.okx.com/docs-v5/en/#overview-demo-trading-services)

## 1. 环境、认证与时间

- 全球站当前文档给出的生产服务为 REST `https://openapi.okx.com`、WS `wss://ws.okx.com:8443/ws/v5/{public,private,business}`；Demo REST 仍为 `https://openapi.okx.com`，WS 为 `wss://wspap.okx.com:8443/ws/v5/{public,private,business}`，并要求 Demo REST 请求带 `x-simulated-trading: 1`。地区实体会给出不同主机名，因此配置必须记录 `entity/region + rest_base + public_ws + private_ws + business_ws + simulated`。[Demo Trading Services](https://www.okx.com/docs-v5/en/#overview-demo-trading-services)
- Demo key 与生产 key 分离；私有 REST 需要 `OK-ACCESS-KEY/SIGN/TIMESTAMP/PASSPHRASE`。签名原文为 `timestamp + METHOD + requestPath + body`，HMAC-SHA256 后 Base64；查询串属于 `requestPath`。[REST Authentication](https://www.okx.com/docs-v5/en/#overview-rest-authentication)
- 私有 WS 登录使用 key/passphrase/timestamp/sign；Adapter 必须以官方 WS 登录合同生成签名，不复用 REST ISO 时间字符串的编码假设。[WebSocket Login](https://www.okx.com/docs-v5/en/#overview-websocket-login)
- REST 时间戳与服务器时间相差超过 30 秒会以 `50102` 拒绝。启动及时钟异常后应调用 `GET /api/v5/public/time` 估算偏移；2026-08-11 05:10:33.540Z 的第一方公开响应成功返回 `code=0`。[Get system time](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-system-time)
- WS 30 秒无订阅或无推送可能断开；客户端应在小于 30 秒的空闲窗口发送文本 `ping` 并期待 `pong`，失败即重连。登录/订阅/退订合计每连接 480 次/小时，建连为每 IP 每秒 3 次。[WebSocket Connect](https://www.okx.com/docs-v5/en/#overview-connect)
- Place/Batch Place/Amend/Batch Amend 支持 `expTime`（毫秒 deadline）；超时只约束服务端是否继续处理，客户端超时或丢响应仍必须进入 `Unknown` 并对账。[Transaction Timeouts](https://www.okx.com/docs-v5/en/#overview-transaction-timeouts)

## 2. InstrumentRules 与单位

实现必须以 `GET /api/v5/account/instruments` 作为“当前账户可交易”权威规则，以公共 `GET /api/v5/public/instruments` 和 WS `instruments` 做启动/变更输入。至少版本化 `state/ruleType/tickSz/lotSz/minSz/maxLmtSz/maxMktSz/maxLmtAmt/maxMktAmt/ctType/ctVal/ctValCcy/settleCcy/tradeQuoteCcyList/upcChg`；仅看到 `state=live` 才允许常规下单，`SWAP state=post_only` 时只允许 post-only、amend、cancel。[Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments) [2026-05-06 changelog](https://www.okx.com/docs-v5/log_en/#2026-05-06)

2026-08-11 05:10:33Z 对全球站公开 API 的观测快照（不是永久常量，也不是 Demo 账户资格证明）：

| Instrument | `state` | `tickSz` | `lotSz` | `minSz` | 关键单位 |
|---|---:|---:|---:|---:|---|
| `BTC-USDT` | `live` | `0.1` USDT | `0.00000001` BTC | `0.00001` BTC | Limit `sz` 为 base；Market 由 `tgtCcy` 决定 |
| `BTC-USDT-SWAP` | `live` | `0.1` USDT | `0.01` contract | `0.01` contract | linear；`ctVal=0.01 BTC`；`settleCcy=USDT` |

证据接口：[SPOT instruments](https://www.okx.com/api/v5/public/instruments?instType=SPOT&instId=BTC-USDT)、[SWAP instruments](https://www.okx.com/api/v5/public/instruments?instType=SWAP&instId=BTC-USDT-SWAP)。资格票仍须用 Demo 私有 `account/instruments` 重新记录同一字段集并比较差异。

## 3. 公共行情连续性

- 首波使用普通 `books`：初始 400 档 snapshot，之后每 100ms 聚合增量。`books-l2-tbt`/`books50-l2-tbt` 的 10ms 频道有权限及互斥约束，不是本波依赖。[Order book channel](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-ws-order-book-channel)
- 每条 snapshot/delta 记录 `seqId/prevSeqId`。正常增量要求本条 `prevSeqId == 上条 seqId`；约 60 秒无变化时的空增量可能为 `asks=[]/bids=[]` 且 `prevSeqId==seqId==lastSeqId`，应视为 heartbeat。出现缺口、倒序、未知 action 或重订阅时丢弃本地 book，等待新 snapshot，期间禁止发布可交易 book。[Order book sequencing](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-ws-order-book-channel)
- 2026-06-02 Demo、2026-06-23 production 起，`books/books-l2-tbt/books50-l2-tbt` 的 `checksum` 虽保留字段但恒为 `0`，不得用于校验；只用 `seqId/prevSeqId`。[Checksum deprecation announcement](https://www.okx.com/en-us/help/okx-order-book-channels-checksum-field-deprecation)
- SWAP 同时订阅 `mark-price`、`index-tickers`、`funding-rate`；REST 对应 `public/mark-price`、`market/index-tickers`、`public/funding-rate` 用于启动/恢复。资金费率间隔不是固定 8 小时，必须按 `fundingTime/nextFundingTime` 计算并分别保存预测 `fundingRate` 与结算 `settFundingRate/settState`。[Mark price](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-mark-price) [Index tickers](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-index-tickers) [Funding rate channel](https://www.okx.com/docs-v5/en/#public-data-websocket-funding-rate-channel)

## 4. 私有事实与恢复

- `orders` 私有频道订阅后**没有初始快照**，仅推新订单和更新。因此启动顺序必须是：建立并订阅 WS、记录 ingress watermark、REST 拉 `orders-pending` + 相关 order/history/fills，再把缓冲的 WS 更新按幂等键合并；重连同样处理。[Orders channel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-order-channel)
- `account` 与 `positions` 有 initial/regular snapshot 和 event update，但只推非零余额/非零仓位；零值消失不能单靠“未出现”推断，清仓与余额归零需 REST 核实。Position 的 `posId` 可过期/重建，领域键应至少包含 `instId + mgnMode + posSide`，`posId` 只作 venue identity。[Account channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-account-channel) [Positions channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-positions-channel)
- REST 恢复集合：`GET /api/v5/trade/orders-pending`、`GET /api/v5/trade/order`、`orders-history`（7 天；未成交撤单仅保留 2 小时）、`orders-history-archive`（3 个月）、`fills`/`fills-history`、`account/balance`、`account/positions`。历史窗口不能替代本地原始日志。[Order list](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-list) [Order history 7 days](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-history-last-7-days) [Order history 3 months](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-history-last-3-months)
- 分页不是统一抽象：订单通常以 `ordId`，成交以 `billId/tradeId`，仓位历史以 `uTime`；`after` 通常取更旧、`before` 取更新，但必须逐 endpoint 实现并用边界去重，不能做一个猜测语义的通用 paginator。

## 5. 订单能力映射

| 既定能力 | OKX v5 映射与约束 |
|---|---|
| Limit + GTC | `ordType=limit`；`px` 必填 |
| Market | `ordType=market`；SPOT `sz` 单位由 `tgtCcy` 决定，并必须由本地价格保护/名义上限包围；可使用当前 `slippagePct`，但不能把 Venue 默认当风险上限 |
| IOC / FOK | `ordType=ioc/fok`；Limit 价格语义仍需本地规范化 |
| Post-only | `ordType=post_only`；穿价失败可能直接只推 `canceled`，不能要求先见 `live` |
| VenueReduceOnly | SWAP net mode 传 `reduceOnly=true`；超出现有仓位会整单拒绝，不会自动裁剪 |
| 原地 amend | `POST /api/v5/trade/amend-order` 或 WS `amend-order`，用 `ordId` 或 `clOrdId`；提供唯一 `reqId` 关联；保持 `cxlOnFail=false` |
| 精确 cancel | `instId + ordId/clOrdId`；响应 `sCode=0` 只代表系统接受，终态由 Orders WS/REST order 确认 |
| TransportBatch | place/amend/cancel 各最多 20 项，非原子；逐项解析 `sCode/sMsg/subCode`，顶层 `code=2` 表示部分成功 |

来源：[Place order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)、[Amend order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-amend-order)、[Cancel order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-cancel-order)、[Batch operations best practice](https://www.okx.com/docs-v5/trick_en/#batch-operations)。

`clOrdId` 只保证当前 pending 集合内唯一，终态后可以复用；本系统必须更严格地永久不复用，以便 Unknown 对账。`GET trade/order` 同时给 `ordId` 和 `clOrdId` 时优先 `ordId`，按复用过的 `clOrdId` 查询只返回最近一条，因此本地关联不能依赖 OKX 的历史唯一性。

2026-07-16 公告还有一项尚在灰度日期上的行为：post-only 的 `live` 将延迟到真正入簿（约 1ms），穿 BBO 失败只推 `canceled`；Demo/production 均计划于 2026 年 8 月中旬切换。实现必须兼容切换前后两种序列，资格证据记录实际观察行为，不能以日期猜测。[Orders push adjustment](https://www.okx.com/en-us/help/okx-websocket-orders-channel-push-behavior-adjustment-announcement-us)

## 6. 限流、错误与 Unknown

- 公共 REST 通常按 IP，私有 REST 按 User ID，WS order management 按 User ID；place/amend/cancel 的 REST 与 WS 配额共享，三类操作互相独立，通常按 instrument ID。单笔 place/amend/cancel 当前为 60/2s；批量 place/amend 为 300 orders/2s，cancel batch 为 300 orders/2s；批量每项计数，且仅含 1 项时采用单笔桶。[Rate limits](https://www.okx.com/docs-v5/en/#overview-rate-limits)
- 另有 sub-account 总桶（新单+amend）及可能的 fill-ratio 桶；不能只实现 endpoint 桶。`50011` 是通用 rate-limit，`50061` 是 sub-account rate-limit；应保留原始 HTTP、顶层 `code/msg`、逐项 `sCode/sMsg/subCode` 供版本化映射。
- 稳定分类由 Adapter 建立，而不是把数字范围硬编码为语义：`throttle`（如 50011/50061）、`auth/time`（如 50102）、`validation/capability`、`risk/funds`（如 51008 及 subCode）、`not_found/already_terminal`（如 51063/51400）、`venue_busy/retryable`、`unknown_outcome`。未知新 code 默认不可重试且保存原值，更新 code 表需独立版本。
- HTTP 200 不代表业务成功；批量顶层成功也不代表各项成功。place/amend/cancel 的 `sCode=0` 也只是请求被系统接受，不证明最终 live/amended/canceled。
- 下列情况进入 `Unknown`：请求已可能发出但没有可解析逐项确认、网关/客户端超时、连接在写后断开、响应损坏、收到可重试 venue error 但官方未保证未执行。禁止盲目重发；先以永久唯一 `clOrdId` 查询 `GET trade/order`，再检查 pending/history/fills，直到找到事实或超过有审计记录的人工处置期限。

## 7. Demo 与生产必须版本化的差异

每次资格运行保存（不得含凭证）：

1. 文档/changelog 抓取日期、OKX entity/region、所有 base URL、`x-simulated-trading` 值。
2. Demo `account/config` 的 account mode、position mode、权限/KYC 错误，Demo 私有 `account/instruments` 的完整规则快照。
3. Demo 与同日 production public instruments 的字段 diff；公共 WS 频道实际可订阅性、snapshot/delta schema、seq 行为。
4. 各订单类型的实际 ACK + Orders WS 状态序列，尤其 post-only 灰度；batch 部分成功、amend、reduce-only 超仓拒绝。
5. endpoint/sub-account 实测限流 header/code；所有未知 code 原文。
6. Demo 流动性与是否可重复制造部分成交、FOK/IOC、断线窗口。官方只承诺 API 可用于 Demo，并明确部分功能不支持；没有承诺 Demo 流动性、撮合与生产等价，所以 Demo 只能证明功能集成，不能证明生产成交质量或生产资格。

Demo 特有能力 `POST /api/v5/account/adjust-balance`（2026-05-07 加入）可为验收补充 BTC/ETH/USDT/OKB，增加有每日次数及单次额度；它只用于测试准备，不进入产品交易 seam。[Adjust demo account balance changelog](https://www.okx.com/docs-v5/log_en/#2026-05-07)

## 8. 对后续票据的硬结论

- Adapter config 必须显式区分 `demo` 与 `production`，且生产模式在本地图构建中 fail-closed；endpoint 由 region/entity profile 提供。
- L2 不实现 checksum；只实现 `seqId/prevSeqId` 连续性和 snapshot 重建。
- Orders WS 无 snapshot，因此 REST+WS 启动/重连 barrier 是 interface 的必需生命周期，而非实现细节。
- ACK 永远不是终态；所有写请求都需要确定性 client id、RawIngress 记录和 Unknown 对账。
- InstrumentRules、错误码映射、endpoint profile、观察到的 Demo schema/行为都带 evidence timestamp/version。

## 尚存雾区

- 官方没有保证 Demo 可稳定制造“部分成交”或传输 Unknown；需要在失败恢复票中选定可审计的 Adapter 边界故障注入，并把真实 Demo 能复现的场景作为补充而非唯一验收。
- 2026 年 8 月中旬 post-only 推送调整没有精确生效时刻；资格票必须同时接受新旧序列并记录实测。
- Demo 私有账户的 region/entity endpoint、account mode、position mode、tradeQuoteCcy、instrument rule diff 只有在不泄露凭证的预检中才能确认。
