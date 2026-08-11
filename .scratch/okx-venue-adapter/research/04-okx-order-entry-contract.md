# OKX v5 订单写入合同

研究日期：2026-08-11（UTC）

范围：第 08 票的 `BTC-USDT` SPOT 与 `BTC-USDT-SWAP`；只使用 OKX 官方 API v5 文档、Best Practice 与 Change Log。本文固定 wire contract，不读取凭据、不执行订单。

## 结论

OKX REST 与 private WS 都提供单笔及最多 20 项的 place/amend/cancel，订单能力足以覆盖 Limit/GTC、Market、IOC、FOK、post-only、SWAP isolated net-mode reduce-only 和真正原地 amend。但两条传输不是字段完全相同的镜像：REST 继续用 `instId`，WS order operations 当前必须用由 Instruments 映射的整数 `instIdCode`；WS 的 `instId` 在 place/batch place 已 delist，在 amend/cancel 已 deprecated 并会被忽略。[2026-03-26/04-07 Change Log](https://www.okx.com/docs-v5/log_en/#2026-04-07)

接口冻结的发送边界应保持不变：只有首次触网前的本地失败是 `NotSent`；收到完整成功 ACK 才是 `Submitted`，但 ACK 不证明订单已 live、改单已生效或撤单已完成；可能已发出而没有可解释 ACK 的请求一律 `Unknown`。官方没有给任意 HTTP 状态或超时错误提供历史级 exactly-once 保证，因此不能按错误码名称自动重放。[Order management best practice](https://www.okx.com/docs-v5/trick_en/#order-management) [Transaction timeouts](https://www.okx.com/docs-v5/en/#overview-transaction-timeouts)

## 1. 端点与消息外壳

| 操作 | REST | private WS `op` | 上限/当前基础桶 |
|---|---|---|---|
| Place | `POST /api/v5/trade/order` | `order` | 单笔；60 requests / 2s |
| Batch place | `POST /api/v5/trade/batch-orders` | `batch-orders` | 最多 20；300 orders / 2s |
| Amend | `POST /api/v5/trade/amend-order` | `amend-order` | 单笔；60 requests / 2s |
| Batch amend | `POST /api/v5/trade/amend-batch-orders` | `batch-amend-orders` | 最多 20；300 orders / 2s |
| Cancel | `POST /api/v5/trade/cancel-order` | `cancel-order` | 单笔；60 requests / 2s |
| Batch cancel | `POST /api/v5/trade/cancel-batch-orders` | `batch-cancel-orders` | 最多 20；300 orders / 2s |

来源：[REST Trade](https://www.okx.com/docs-v5/en/#order-book-trading-trade)；[WS Place](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-place-order)、[WS Amend](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-amend-order)、[WS Cancel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-cancel-order)。

REST body 是单个 object 或 batch array。WS 写入统一发到 `/ws/v5/private`：外层 `id` 是本次 WS 请求关联 ID（1–32 位大小写敏感字母数字），`op` 取上表值，`args` 为一项或多项；响应原样回显 `id/op`，并给顶层 `code/msg`、`data[]`、`inTime/outTime`。

REST 每个请求项以字符串 `instId` 指定产品。WS 每项使用整数 `instIdCode`；它来自 `GET /api/v5/{public|account}/instruments` 或 Instruments channel，并须与当前规则版本一起缓存。对当前 WS place/batch place 发送 `instId` 会被忽略；amend/cancel 的 `instId` 也已 deprecated/ignored。若同时出现，官方文档规定 `instIdCode` 优先。[WS order operation migration](https://www.okx.com/docs-v5/log_en/#2026-04-07) [Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)

实现含义：首版若只选 REST 写入，可避免维护第二套请求 codec；若启用 WS 写入，`instIdCode` 是资格化依赖，不能从字符串猜出，也不能在规则版本漂移后继续发送旧 command。

## 2. Place 公共字段和产品映射

两条传输的每个 place item 至少需要：instrument identity、`tdMode`、`side`、`ordType`、`sz`；建议总是给永久唯一的 `clOrdId`。`px` 对 `limit/post_only/fok/ioc` 必填，对 `market` 不发送。可选的 `expTime` 为毫秒请求 deadline；REST 放 header，WS 放请求参数。[Place order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order) [WS Place order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-place-order)

| Canonical command | `BTC-USDT` SPOT | `BTC-USDT-SWAP` isolated net mode |
|---|---|---|
| Limit + GTC | `tdMode=cash`, `ordType=limit`, `px`, `sz` 为 BTC；不发 `posSide/reduceOnly` | `tdMode=isolated`, `ordType=limit`, `px`, `sz` 为 contracts；`posSide` 省略或 `net` |
| Market | `tdMode=cash`, `ordType=market`, 明确 `tgtCcy` 与 `sz` | 原生为 `tdMode=isolated`, `ordType=market`, `sz` 为 contracts；见下节保护约束 |
| IOC | `ordType=ioc` + `px` | 同左 |
| FOK | `ordType=fok` + `px` | 同左 |
| Post-only | `ordType=post_only` + `px` | 同左；若 instrument `state=post_only`，其他类型会被拒绝 |
| VenueReduceOnly | 不适用于 cash SPOT | `reduceOnly=true`；仅 net mode 可显式使用 |

OKX 没有独立 `timeInForce` 字段；普通 `ordType=limit` 是本系统 GTC 的直接映射，IOC/FOK/post-only 各用独立 `ordType`，不得把 GTC 再编码成自造参数。[Order types](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)

SPOT cash 必须是 `tdMode=cash`，不得发送 `posSide`。SWAP 逐仓必须是 `tdMode=isolated`；目标账户为 net mode 时 `posSide` 可省略，若发送只能是 `net`。`reduceOnly` 只适用于 MARGIN 及 FUTURES/SWAP net mode，且在 Futures mode/Multi-currency margin 下有效；目标 SWAP reduce-only command 必须显式传 `true`。[Place order parameter notes](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)

`reduceOnly=true` 不是本地仓位检查的替代品：对同一 SWAP，当前请求与更高 price-time priority 的反向 reduce-only 挂单合计不能超过仓位数量。Adapter 仍需以权威仓位限制方向/数量并原样保留 venue reject。[Reduce-only semantics](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)

## 3. Market 数量与价格保护

SPOT market 的 `sz` 没有固定单位，必须显式带 `tgtCcy`：

- buy + `quote_ccy`：`sz` 是要花的 USDT（官方默认）；
- buy + `base_ccy`：`sz` 是要买到的 BTC；
- sell + `base_ccy`：`sz` 是要卖的 BTC（官方默认）；
- sell + `quote_ccy`：`sz` 是要收到的 USDT。

若用“到手币种”（buy `base_ccy` 或 sell `quote_ccy`），OKX 可能因余额/波动按 best effort 自动缩量。为保持不可变 command，发送 `banAmend=true`，余额不足时让 Venue 拒绝而不是静默改 `sz`。[SPOT Market `tgtCcy` and `banAmend`](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)

2026-05-06 起，上述“到手币种”的 SPOT/spot-margin market 支持 `slippagePct`，范围 `0`–`0.05`；它同时适用于 REST/WS 单笔与批量 place。值必须由版本化风险/命令给出，不能依赖 Venue 默认。[Slippage tolerance change](https://www.okx.com/docs-v5/log_en/#2026-05-06)

原生 SWAP `ordType=market` 没有等价的 `slippagePct` 参数；SPOT 的“花出 quote / 卖出 base”两种 market side 也不在该参数的官方适用条件内。因此“禁止无界 Market”的可证明实现不能只发送原生 market：必须用新鲜连续 L2 和价格限制计算一个最坏成交价，再映射成 `ordType=ioc + px`，或在不能证明保护时 `NotSent/CapabilityUnsupported`。这是由官方参数适用范围导出的系统约束，不是 OKX 对 IOC 成交量的保证。[Place order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order) [Price limit](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-limit-price)

`pxAmendType` 必须保持默认/显式 `0`，防止 OKX 在输入价格越过 price limit 时替 Adapter 改价；不能使用 `1` 的自动修价。SPOT market 的 `banAmend=true` 与这个价格字段是两件事。[Place price-amend semantics](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)

## 4. 身份合同

- `clOrdId`：place 前生成，最多 32 位、大小写敏感字母数字；OKX 只保证当前 pending 订单集合内唯一，终态后允许复用。本系统必须永久不复用。现有示例 `RWN-0001` 含连字符，不符合官方字母数字合同，真实 codec 应改为纯字母数字。[Identifiers](https://www.okx.com/docs-v5/trick_en/#identifiers) [Place order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-order)
- `ordId`：OKX 在成功 place ACK 返回的 venue order identity；取得后成为 query/amend/cancel 首选键。查询或写入同时给 `ordId/clOrdId` 时，官方优先 `ordId`。[Get order details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details)
- `reqId`：每次 amend 的 client request identity，最多 32 位大小写敏感字母数字；必须永久唯一。ACK 和 Orders channel 会回传，用于区分重复/迟到改单结果。[Amend order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-amend-order) [Order channel revamp](https://www.okx.com/docs-v5/log_en/#order-channel-revamp)
- WS 外层 `id`：只关联一个 WS command/response，不代替 `clOrdId/reqId`，也不作为订单身份。

`GET /api/v5/trade/order` 同时传 `ordId/clOrdId` 时采用 `ordId`；若历史复用了 `clOrdId`，只返回最新一笔。因此 Unknown 查询只能依赖本系统永久唯一 `clOrdId`，发现 `ordId` 后转用 `ordId`。[Get order details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details)

## 5. Amend 与 Cancel

Amend 每项字段：REST `instId` / WS `instIdCode`，`ordId` 或 `clOrdId`，唯一 `reqId`，以及至少一个 `newSz/newPx`。`newSz` 是修改后的**总目标数量**，不是剩余量；若已成交 3、目标总量 8，应传 8。对部分成交订单传 `newSz <= 已成交量` 可能把订单状态变成 filled。[Amend order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-amend-order)

始终显式 `cxlOnFail=false`。官方说明改单 ACK 的 `sCode=0` 仅表示 server 接受请求，最终结果由 Orders channel 或 order query 决定；后续失败时 `amendResult=-1` 且原单继续。`cxlOnFail=true` 会把后续改单失败变成自动撤单，违反本项目禁用项。[Amend result semantics](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-amend-order)

Amend 的 `pxAmendType=0`，不允许 Venue 自动修到 price limit。不能在改单响应未知时推断旧单未变；必须查询 `state/px/sz/accFillSz/reqId/amendResult`。

Cancel 每项只带 REST `instId` / WS `instIdCode` 与 `ordId` 或 `clOrdId`。`sCode=0` 只表示撤单请求已被系统接受；只有 Orders `state=canceled` 或 GET order 的终态能证明完成。[Cancel order](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-cancel-order) [Cancel best practice](https://www.okx.com/docs-v5/trick_en/#cancel-order)

CancelConfirmCreate 必须保持三步领域流程：发精确 cancel → 等权威 canceled/filled 终态 → 对最新成交/风险重新评估后才生成新 place。OKX 本节端点没有提供本项目可用的原子 cancel-replace 保证。

## 6. Batch 合同

- Place/amend/cancel 单次均最多 20 项；不同 instrument type 可在同一批，但本项目应按安全优先级分批，普通 submit/amend 不与 cancel/reduce-only 混批。[Batch operations](https://www.okx.com/docs-v5/trick_en/#batch-operations)
- Batch 非原子，按输入顺序处理。顶层 `code=0` 表示全成功、`1` 表示全失败、`2` 表示部分成功；格式级错误可令 `data=[]`。每一项独立解析 `ordId/clOrdId/reqId/ts/sCode/sMsg/subCode`，不能用顶层 code 批量决定 20 个领域结果。[WS batch response examples](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-place-multiple-orders)
- 每个成功 place item 的 ACK 给 `ordId/clOrdId/ts/sCode=0`；成功 amend/cancel 同理，但仍只是接受 ACK。部分失败不回滚成功项，也不得扩大重试范围。
- 整批响应丢失时，所有可能触网项分别进入 Unknown；只有能由 libcurl/队列证明确实未触网的尾部项才是 NotSent。对账逐 `clOrdId/ordId`，不能重发整批。

## 7. 限流成本与调度

官方总规则：[Rate Limits](https://www.okx.com/docs-v5/en/#overview-rate-limits)。

- Private REST 与 WS order management 都按 User ID；place/amend/cancel 的 REST 与 WS 共享对应操作桶。
- Place、amend、cancel 三类桶彼此独立，目标 SPOT/SWAP 都按 User ID + Instrument ID。
- 单笔与 batch 桶通常独立；batch 只有 1 项时按对应单笔桶计费。
- Batch 按订单项数计费，不是按 HTTP/WS frame 计 1。
- Sub-account 另有 new+amend 聚合桶；每 batch item 分别计数，超限码 `50061`。Endpoint 桶超限通用码为 `50011`。
- Fill-ratio 动态 sub-account 桶可能与基础桶并行；实现必须把服务端返回和 `GET /api/v5/trade/account-rate-limit` 作为版本化证据，不能假定文档最大值就是当前账户可用值。[Account rate limit](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-account-rate-limit)

调度器至少维护 place-single/place-batch、amend-single/amend-batch、cancel-single/cancel-batch 与 sub-account new+amend 约束；为 cancel、VenueReduceOnly 与 reconciliation 保留独立容量。一个请求在真正加入 libcurl handle 前再次检查 deadline、规则版本与所需所有桶。

## 8. `NotSent / Submitted / Unknown` 的可证明边界

| 观察 | Dispatch 分类 | 可证明内容 |
|---|---|---|
| 本地规范化/版本/权限 gate 拒绝、队列背压，或首次加入 libcurl 前 deadline 到期 | `NotSent` | Adapter 能证明未触网 |
| 完整 REST/WS item ACK：顶层可解析，item `sCode=0` 且 place 有 `ordId` | `Submitted` | OKX server 已接受该请求；不证明订单终态 |
| 完整业务拒绝：item `sCode!=0` | `Submitted` + Canonical reject | 请求已触网且该 item 有权威拒绝；不能把整批其他项类推失败 |
| HTTP 非 2xx、无/损坏 body、gateway/client timeout、写后断连、WS 无匹配 `id` ACK、顶层错误但缺逐项结果 | `Unknown` | 请求可能已到达；官方未证明未受理 |
| `expTime` 在首次触网前已过期 | `NotSent/DeadlineExpired` | 本地可证明未发送 |
| 已发送后服务端因 `expTime` 判断过期 | 不用错误名猜 dispatch；保留原始响应并按 Unknown/明确 reject 合同处理 | `expTime` 只保证服务器时钟已过时“不处理”，不赋予网络 exactly-once |

官方定义 `inTime` 是 gateway 收到请求（REST 在认证后）的微秒时间、`outTime` 是 gateway 发响应时间；若响应完整可保存为接入证据，但它们不是撮合 watermark。[Order timestamps](https://www.okx.com/docs-v5/trick_en/#order-timestamp)

成功 place ACK 后，Orders channel 的 `live/partially_filled/filled/canceled` 或 REST reconciliation 才形成权威 ExecutionReport。成功 amend/cancel ACK 也分别不能证明修改/撤销完成。任何 Unknown 禁止自动重放交易 POST。[Place and amend acknowledgements](https://www.okx.com/docs-v5/trick_en/#order-management)

## 9. 查询与对账字段

Unknown place 首选 `GET /api/v5/trade/order?instId=...&clOrdId=...`；取得 `ordId` 后固定使用 `ordId`。同时检查：

- identity/input：`instType/instId/ordId/clOrdId/reqId/tdMode/tgtCcy/side/posSide/ordType/px/sz/reduceOnly`；
- state/result：`state/accFillSz/avgPx/tradeId/fillPx/fillSz/fillTime/fee/feeCcy/pnl`；
- amend/cancel：`reqId/amendResult/cancelSource/cancelSourceReason`；
- ordering：`cTime/uTime`。

来源：[Get order details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details)。

单笔查无结果不能立即证明 ConfirmedAbsent；继续查询 `orders-pending`、近 7 天 `orders-history`、近 3 个月 `orders-history-archive`、近 3 天 `fills`/近 3 个月 `fills-history`，并合并已缓冲 Orders WS。Orders WS 订阅没有初始快照，不能单独承担 Unknown 恢复。[Order list/history](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-list) [Transaction details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-transaction-details-last-3-days) [Orders channel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-order-channel)

Unknown amend 查询必须比较原始 `px/sz`、目标 `newPx/newSz`、`reqId/amendResult`、累计成交与终态；Unknown cancel 查询 `state` 与成交。对账找不到、窗口不足或事实冲突时维持 Unknown 与风险占用，不把 absence 猜成失败。

## 10. 当前变更风险与实现硬点

- 纯字母数字 ID：当前产品测试字符串中的 `RWN-0001` 不能直接上 OKX；`clOrdId/reqId/WS id` codec 需生成 <=32 位字母数字并永久唯一。
- WS request identity：当前 API 已从 `instId` 迁到 `instIdCode`，这是 REST/WS codec 的实质差异；资格样本必须证明 SPOT/SWAP code 映射和规则版本漂移行为。
- Post-only push 灰度：OKX 计划在 2026 年 8 月中旬调整 post-only Orders push；穿 BBO 失败将只推 `canceled` 而不先推 `live`。实现必须兼容 `live→canceled` 与直接 `canceled`，不能把缺少 `live` 当丢事件。[Orders push adjustment](https://www.okx.com/en-us/help/okx-websocket-orders-channel-push-behavior-adjustment-announcement-us)
- Bounded Market：SWAP 原生 market 没有 slippagePct；如果 canonical Market 必须有硬价格边界，首版应资格化 IOC-limit 映射，不应静默降级为原生 market。
- `cxlOnFail=false`、`pxAmendType=0`、SPOT received-currency market 的 `banAmend=true` 都应由 codec 强制，不能让调用者任意覆盖。
