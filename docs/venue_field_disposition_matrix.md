# Venue 字段处置矩阵与 CapabilityProfile 证据

> 状态：已审核的设计输入；不授予任何交易权限
> 更新：2026-08-31
> 范围：OKX、Binance、Bybit 的现货和 USDT 线性永续；对应 #7、父 Spec #5
> 架构：[`docs/adr/0001-separate-venue-execution-and-market-feed-seams.md`](adr/0001-separate-venue-execution-and-market-feed-seams.md)

本文件取代旧的“字段覆盖率分析”。它不是字段数量统计，完成条件是：本文件列出的每个
官方目标消息字段都有一种处置，且每个 `Canonical` 引用都有完整的类型、单位、必填和缺失
规则。资料中出现某个字段或能力，**不**表示 RingWin 已实现或获资格使用它。

完整的一手资料索引、访问日期和各消息的完整字段表链接在
[`docs/research/2026-08-28-venue-message-inventory.md`](research/2026-08-28-venue-message-inventory.md)。
该索引是本矩阵的审核证据；资料变更时必须一起复核。

## 1. 读取方式与范围边界

### 1.1 目标消息

“字段”指下列当前第一方消息/响应表中出现的顶层或嵌套字段；`[]` 之后的成员逐项处置，
`filter.*` 等嵌套对象也不省略。REST 分页、认证头和 WebSocket 包络也被纳入，因为它们
决定审计、顺序与资格，却不会泄漏进核心事实。

| Venue | 现货目标消息 | 线性永续目标消息 | 一手资料 |
|---|---|---|---|
| OKX | 私有 `orders`、`fills`、`balance_and_position`；`public/instruments?instType=SPOT` | 私有 `orders`、`fills`、`positions`、`balance_and_position`；`public/instruments?instType=SWAP` | [orders](https://www.okx.com/docs-v5/en/#web3-dex-solana-trading-websocket-private-channel-order-channel)、[account/positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions)、[instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments) |
| Binance | User Data Stream `executionReport`、`outboundAccountPosition`、`balanceUpdate`；`exchangeInfo`；public depth | USD-M User Data Stream `ORDER_TRADE_UPDATE`、`ACCOUNT_UPDATE`；`exchangeInfo`；public depth / mark price | [Spot user stream](https://developers.binance.com/docs/binance-spot-api-docs/user-data-stream)、[Spot exchange info](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/general-endpoints#exchange-information)、[Spot depth](https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams#diff-depth-stream)、[USD-M user stream](https://developers.binance.com/docs/derivatives/usds-margined-futures/user-data-streams/Event-Order-Update)、[USD-M exchange info](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Exchange-Information)、[USD-M market streams](https://developers.binance.com/docs/derivatives/usds-margined-futures/websocket-market-streams/Mark-Price-Stream) |
| Bybit | v5 private `order`、`execution`、`wallet`；`instruments-info?category=spot`；public orderbook | v5 private `order`、`execution`、`position`、`wallet`；`instruments-info?category=linear`；public orderbook/ticker | [order](https://bybit-exchange.github.io/docs/v5/websocket/private/order)、[execution](https://bybit-exchange.github.io/docs/v5/websocket/private/execution)、[wallet](https://bybit-exchange.github.io/docs/v5/websocket/private/wallet)、[position](https://bybit-exchange.github.io/docs/v5/websocket/private/position)、[instruments](https://bybit-exchange.github.io/docs/v5/market/instrument)、[orderbook](https://bybit-exchange.github.io/docs/v5/websocket/public/orderbook)、[ticker](https://bybit-exchange.github.io/docs/v5/websocket/public/ticker) |
| Hyperliquid（合同候选，未实现） | `spotMeta`、`spotClearinghouseState`/`spotState`、订单/成交、公共快照/交易 | 标准逐仓 `meta`、`clearinghouseState`、订单/成交/资金费/强平、公共快照/参考价 | [01 协议依据与样本](research/2026-11-02-hyperliquid-protocol-contract.md)；本表 §3.8；不是已激活 Profile |

既有实现仅限 `SPOT`、`SWAP` / USD-M、Bybit `spot` / `linear`；Hyperliquid 候选另限标准 USDC 逐仓和现货。期权、交割合约、组合保证金和
算法订单不在产品范围；它们出现的字段仍在本表中标明拒绝原因，不能被忽略。

### 1.2 处置和明确拒绝规则

| 代码 | 含义 |
|---|---|
| `C:n` | `Canonical`：转换为下表 `n` 定义的稳定领域事实。 |
| `AI:n` | `AdapterInternal`：只供认证、分页、去重、顺序、限流或连接恢复使用。 |
| `RE:n` | `RawEvidence`：RawIngress 保存原值；核心不以它作决定。 |
| `U:n` | `Unsupported`：必须按下表规则拒绝请求或停止该输入，绝不静默降级。 |
| `NA` | `NotApplicable`：在已声明的现货/线性范围没有语义；不得因字段缺失补造值。 |

| 规则 | 触发 | 必须结果 |
|---|---|---|
| `U:product` | 非 SPOT/线性产品、未注册 `Instrument`、不匹配的 settle Asset | `CanonicalRejectReason.unsupported_instrument`，不发送。 |
| `U:order-kind` | 不在 Profile 明确列出的 order type / TIF | `CanonicalRejectReason.capability_unsupported`，不发送。 |
| `U:attached-algo` | trigger、TP/SL、trailing、OCO、conditional/algo 语义 | `CanonicalRejectReason.capability_unsupported`，不发送。 |
| `U:stp` | STP/SMP 需要或回报要求策略语义 | `CanonicalRejectReason.capability_unsupported`，不发送。 |
| `U:margin-mode` | Profile 未资格化的 cross/portfolio/hedge/auto-add-margin 模式 | `CanonicalRejectReason.capability_unsupported`，不发送。 |
| `U:enum` | 未知且影响订单、仓位、费用或资金语义的枚举值 | `CanonicalRejectReason.unsupported_value`，停用该范围的新增风险。 |
| `U:authority` | Profile 未被当前环境、账户、产品和资格证据激活 | `CanonicalRejectReason.capability_unsupported`，不发送。 |

`U:*` 是 CapabilityProfile 的准入规则，不是将来实现的待办占位。`AI:*` 和 `RE:*`
字段若不能先写入 RawIngress 或不能由有界 Adapter 状态处理，也必须失败关闭。

## 2. Canonical 字段注册表

这张表是所有 `C:n` 的唯一完整定义。`Required` 表示适用事实必须携带；`conditional`
表示由产品/状态决定；缺失处理永远在 Adapter seam 发生。

| ID | 目标领域事实与字段 | 类型 / 单位 | 必填条件 | 缺失处理 |
|---|---|---|---|---|
| C1 | `EventEnvelope.venue` | `VenueIdentity` | 全部 Venue 事实 | 拒绝输入 `unsupported_value`。 |
| C2 | `EventEnvelope.adapter_session` | `AdapterSessionIdentity` | 全部私有事实 | 关闭该账户输入并重建 session。 |
| C3 | `EventEnvelope.source_stream` / `source_sequence` | stream identity + `u64` | 每个 REST/WS 来源 | 无 Venue 序号时只生成 capture sequence，不证明交易所连续性；无法表示的证据先补共享合同，不能填造 previous sequence。 |
| C4 | `EventEnvelope.times` | source/receive/monotonic/audit UTC ns | receive/monotonic/audit 必填；source 条件 | 保留 source 缺失位，禁止以 wall time 伪造 source time。 |
| C5 | `EventEnvelope.raw_evidence` | `RawEvidenceRef` | 全部外部输入 | RawIngress 不可写即失败关闭。 |
| C6 | `InstrumentDefinitionObserved`：产品、base/quote/settle Asset、线性合约、状态 | identities + enums | 产品资料响应 | 未注册或非目标产品用 `U:product`。 |
| C7 | `InstrumentRules`：price/quantity scale、tick、lot、min/max qty/notional、contract value | checked integer rules | 可交易产品 | 不能精确转换即 `unsupported_value`；不得舍入。 |
| C8 | `ExecutionReport`：Order/VenueOrder/ClientOrder refs、side、type、TIF、status、原始/累计/剩余量、limit/avg price | opaque refs; enums; `InstrumentQuantity` / `InstrumentPrice` | 所有 owned order 状态 | 身份/状态/必需量缺失或矛盾即拒绝该事实并对账。 |
| C9 | `Fill`：VenueTrade/VenueOrder/ClientOrder refs、side、qty、price、fee+Asset、rebate+Asset、realized PnL+settle Asset、liquidity、fill time | opaque refs; integer amount/price/quantity | 有成交时 | 缺 trade ref、qty、price、fee asset 或不能精确换算即停止经济投影并对账。 |
| C10 | `ExchangeBalanceSnapshot` / `Observed`：Asset 的 total/available/locked/liability | `AssetAmount`，绝对值 | bootstrap 完整快照；增量条件 | 缺完整 scope 不标记 Snapshot；增量缺 bootstrap 则拒绝。 |
| C11 | `ExchangePositionSnapshot` / `Observed`：Instrument、PositionSide、qty、avg/mark/liquidation price、margin、leverage、unrealized PnL | integer quantities/amounts; enums | 线性产品；完整或明确单项范围 | source gap 或范围不完整使该投影无效并对账。 |
| C12 | `ExchangeMarginSnapshot` / `Observed`：equity、initial/maintenance margin、margin mode/risk tier | `AssetAmount`; versioned `MarginRules` | Venue 报告该范围时 | 不用本地推断替代；缺 scope/单位则保留 evidence 并对账。 |
| C13 | `VenueAccountConfigurationSnapshot`：position/margin mode、leverage、trade/read/withdraw authority | enums/bools | session bootstrap 和变更 | 未知或未资格化模式用 `U:margin-mode`；withdraw 必须为 false 才可授予交易资格。 |
| C14 | `OrderDispatchResult` | attempt id + `not_sent|submitted|unknown` + canonical reason | 每次 OrderCommand 尝试 | 缺完整 transport 证据即 `unknown`，绝不自动重发。 |

## 3. 逐字段处置矩阵

为保持逐字段可读性，具有相同字段表的现货/线性消息共用一行并用括号标注产品差异；逗号
分隔的字段是**各自独立字段**，具有同一处置，而不是“其余字段”的通配符。

### 3.1 所有 Venue 的传输包络、认证和分页

| Venue / 消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| OKX REST/WS | `code`, `msg`, `event`, `op`, `connId`, `id`, `arg.channel`, `arg.instType`, `arg.instId`, `arg.uid` | `AI:protocol` | 有界的协议关联、订阅和错误处理；原值也进入 `RE:frame`。 |
| OKX REST | `before`, `after`, `limit` | `AI:pagination` | 完成性/游标证据，不是业务事实。 |
| Binance Spot/Futures WS | `e`, `E`, `T`, `listenKey` | `C4`（时间）；`AI:session`（listenKey） | 事件/交易时间进入 envelope，listen key 不越过 seam。 |
| Binance REST | `code`, `msg`, `serverTime`, `rateLimits[]`, `timezone` | `AI:protocol` | 错误、时钟和限流状态；`serverTime` 仅为证据。 |
| Bybit WS | `topic`, `type`, `ts`, `cts`, `creationTime`, `req_id`, `success`, `retCode`, `retMsg` | `C4`（时间）；`AI:protocol`（其余） | 时间保留，订阅/确认留 Adapter。 |
| Bybit REST | `retCode`, `retMsg`, `retExtInfo`, `time`, `nextPageCursor`, `category` | `AI:protocol` | 分页、响应及类别验证。 |

### 3.2 OKX：orders、account、positions 与 instruments

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| `orders` | `instId`, `instType`, `ordId`, `clOrdId`, `tag`, `side`, `ordType`, `state`, `tgtCcy`, `sz`, `px`, `accFillSz`, `avgPx`, `fillPx`, `fillSz`, `tradeId`, `fillTime`, `cTime`, `uTime` | `C6/C8/C9/C4` | 产品身份、订单生命周期和独立 Fill；时间入 envelope/事实。 |
| `orders` | `tdMode`, `posSide`, `reduceOnly`, `lever`, `stpId`, `stpMode` | `C8/C13`（tdMode/posSide/reduceOnly/lever）；`U:stp`（stpId/stpMode） | 账户/持仓语义必须明确；首波不支持 STP。 |
| `orders` | `fee`, `feeCcy`, `fillFee`, `fillFeeCcy`, `rebate`, `rebateCcy`, `fillPnl`, `execType` | `C9` | 费用、返佣、PnL、maker/taker 都是经济事实。 |
| `fills` | `instId`, `fillSz`, `fillPx`, `side`, `ts`, `ordId`, `clOrdId`, `tradeId`, `execType`, `count` | `C9/C4`（完整的独立成交）；`AI:aggregation`（count） | 此频道可能聚合且非完整；只能补充 `orders` 与 REST 对账，不能作为 bootstrap 的唯一成交来源。 |
| `orders` | `reqId`, `source`, `quickMgnType`, `banAmend`, `pxAmendType`, `cancelSource`, `cancelSourceReason` | `AI:request`; `RE:order-detail` | 请求关联和 Venue 诊断，不定义跨 Venue 语义。 |
| `orders` | `algoClOrdId`, `algoId`, `attachAlgoClOrdId`, `attachAlgoOrds[]`, `tpTriggerPx`, `tpOrdPx`, `slTriggerPx`, `slOrdPx`, `pxUsd`, `pxVol` | `U:attached-algo` | 首波无条件/附带 TP/SL 或期权定价。 |
| `balance_and_position.account` | `ccy`, `eq`, `cashBal`, `availBal`, `frozenBal`, `liab`, `upl`, `isoEq`, `isoLiab`, `crossLiab`, `mgnRatio`, `imr`, `mmr`, `notionalUsd`, `ordFrozen`, `uplRatio` | `C10/C12` | 绝对余额和保证金范围；按 Asset/规则精确转换。 |
| `account` | `adjEq`, `totalEq`, `borrowFroz`, `interest`, `twap`, `disEq`, `coinUsdPrice`, `maxLoan`, `uTime` | `C10/C12/C4` | 余额/保证金补充及时间；没有明确 scope 时只作为 `RE:account-detail`。 |
| `positions` | `instId`, `instType`, `posId`, `posSide`, `mgnMode`, `pos`, `avgPx`, `markPx`, `liqPx`, `margin`, `lever`, `upl`, `uTime` | `C11/C4` | 线性真实持仓及其风险价格。 |
| `positions` | `imr`, `mmr`, `notionalUsd`, `adl`, `liqPenalty`, `interest`, `tradeId`, `cTime`, `last` | `C11/C12/C4` | 风险规则、经济事实和时间；非可精确表示值保留 `RE:position-detail`。 |
| `positions` | `baseBal`, `quoteBal`, `baseBorrowed`, `quoteBorrowed`, `baseInterest`, `quoteInterest` | `NA`（SPOT positions） | 属于保证金现货扩展，不是目标的普通现货 position 消息；账户余额另行处理。 |
| `public/instruments` | `instType`, `instId`, `baseCcy`, `quoteCcy`, `settleCcy`, `ctType`, `ctVal`, `ctValCcy`, `tickSz`, `lotSz`, `minSz`, `maxLmtSz`, `maxMktSz`, `state`, `listTime`, `contTdSwTime` | `C6/C7/C4` | 产品、规则与交易状态的候选事实。 |
| `public/instruments` | `uly`, `instFamily`, `expTime`, `optType`, `stk`, `maxIcebergSz`, `maxTriggerSz`, `maxStopSz`, `maxAlgoSz`, `maxLmtAmt`, `maxMktAmt` | `U:product`（options/futures）；`U:attached-algo`（algo limits）；`RE:rule-detail`（其余） | 不扩展目标产品或算法单。 |

### 3.3 Binance：Spot user stream 与 exchangeInfo

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| Spot `executionReport` | `s`, `c`, `S`, `o`, `f`, `q`, `p`, `P`, `F`, `g`, `C`, `x`, `X`, `r`, `i`, `l`, `z`, `L`, `n`, `N`, `T`, `t`, `I`, `w`, `m`, `M`, `O`, `Z`, `Y`, `Q`, `W`, `V`, `B[]` | `C8/C9/C4`（身份、订单、成交、时间、费用）；`U:attached-algo`（P/g）；`U:stp`（V/B[]） | 普通订单和成交可翻译；算法/OCO/STP 请求必须拒绝。 |
| Spot `executionReport` | `d`, `D`, `j`, `J`, `u`, `U`, `v`, `A`, `b`, `a`, `k` | `U:attached-algo`（d/D）；`RE:order-detail`（j/J/u/U/v/A/b/a/k） | trailing 不支持；策略/分配/预防细节留证据。 |
| Spot `outboundAccountPosition` | `u`, `B[].a`, `B[].f`, `B[].l` | `C10/C4` | 每 Asset 的 total/free/locked 是绝对账户观察。 |
| Spot `balanceUpdate` | `a`, `d`, `T` | `RE:balance-change/C4` | 增量变动不能伪装为绝对余额；用来触发对账。 |
| Spot `exchangeInfo` | `symbols[].symbol`, `status`, `baseAsset`, `baseAssetPrecision`, `quoteAsset`, `quotePrecision`, `baseCommissionPrecision`, `quoteCommissionPrecision`, `orderTypes[]`, `icebergAllowed`, `ocoAllowed`, `quoteOrderQtyMarketAllowed`, `allowTrailingStop`, `cancelReplaceAllowed`, `amendAllowed` | `C6/C7`（身份/精度/状态/普通 order types）；`U:attached-algo`（iceberg/OCO/trailing）；`RE:capability-detail`（其余） | 形成规则候选与 Profile 资料，不据文档直接授权。 |
| Spot `exchangeInfo` | `filters[].filterType`, `minPrice`, `maxPrice`, `tickSize`, `minQty`, `maxQty`, `stepSize`, `minNotional`, `maxNotional`, `limit`, `maxNumOrders`, `maxNumAlgoOrders`, `applyToMarket`, `avgPriceMins` | `C7`（价格/数量/名义规则）；`AI:limit`（limit）；`U:attached-algo`（maxNumAlgoOrders）；`RE:rule-detail`（其余） | 精确规则和有界限制。 |
| Spot order transport | canonical `OrderCommand` 的 client order id、side、type、TIF、quantity、price、reduce-only、revision 与 deadline | `AI:transport`；结果为 `OrderDispatchResult` | 私有 codec 只接收 Canonical 值；TIF/post-only/reduce-only/amend 必须在已激活 CapabilityProfile 下复核，超时或过期版本不得发送。 |

### 3.4 Binance：USD-M user stream 与 exchangeInfo

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| `ORDER_TRADE_UPDATE.o` | `s`, `c`, `S`, `o`, `f`, `q`, `p`, `ap`, `sp`, `x`, `X`, `i`, `l`, `z`, `L`, `N`, `n`, `T`, `t`, `b`, `a`, `m`, `R`, `wt`, `ot`, `ps`, `cp`, `rp`, `pP`, `si`, `ss`, `V`, `pm`, `gtd` | `C8/C9/C11/C4`（普通订单、成交、position side、PnL、时间）；`U:attached-algo`（sp/wt/cp/gtd）；`U:stp`（V）；`RE:order-detail`（b/a/pP/si/ss/pm/ot） | 按 Profile 只接受明确资格化的 normal limit/market/IOC/FOK/post-only。 |
| `ORDER_TRADE_UPDATE` | `e`, `E`, `o` | `C4`（e/E）；`AI:envelope`（o） | 消息类别和时间证据。 |
| `ACCOUNT_UPDATE.a.B[]` | `a`, `wb`, `cw`, `bc` | `C10` | wallet/cross wallet/余额变动作为绝对账户范围的一部分。 |
| `ACCOUNT_UPDATE.a.P[]` | `s`, `pa`, `ep`, `cr`, `up`, `mt`, `iw`, `ps`, `bep` | `C11/C12` | 线性持仓、margin mode、isolated wallet、PnL。 |
| `ACCOUNT_UPDATE` | `e`, `E`, `T`, `a.m`, `a` | `C4`（时间）；`RE:account-detail`（reason） | reason 不可成为余额语义替代。 |
| USD-M `exchangeInfo.symbols[]` | `symbol`, `pair`, `contractType`, `deliveryDate`, `onboardDate`, `status`, `baseAsset`, `quoteAsset`, `marginAsset`, `pricePrecision`, `quantityPrecision`, `baseAssetPrecision`, `quotePrecision`, `underlyingType`, `underlyingSubType[]`, `settlePlan`, `triggerProtect`, `liquidationFee`, `marketTakeBound`, `maxMoveOrderLimit` | `C6/C7`（目标线性身份/规则）；`U:product`（非 perpetual）；`U:attached-algo`（triggerProtect）；`RE:rule-detail`（其余） | 只激活 USDT perpetual。 |
| USD-M `exchangeInfo.filters[]` | `filterType`, `minPrice`, `maxPrice`, `tickSize`, `maxPrice`, `minQty`, `maxQty`, `stepSize`, `limit`, `notional`, `multiplierUp`, `multiplierDown`, `multiplierDecimal`, `maxNumOrders`, `maxNumAlgoOrders`, `maxNumIcebergOrders`, `maxPosition` | `C7`（price/qty/notional）；`AI:limit`（limit）；`U:attached-algo`（algo/iceberg）；`RE:rule-detail`（其余） | 规则必须在 ConfigEvent 处激活。 |
| USD-M order transport | canonical `OrderCommand` 的 client order id、side、type、TIF、quantity、price、VenueReduceOnly、revision 与 deadline | `AI:transport`；结果为 `OrderDispatchResult` | 签名、限流和响应关联不越过 seam；无完整 RawIngress 响应、写入不确定或未知状态均失败关闭，绝不自动重发。 |

### 3.5 Binance：公共 L2 与参考价格

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| Spot / USD-M REST depth snapshot | `lastUpdateId`, `bids[][price, quantity]`, `asks[][price, quantity]` | `C3/C5/C7` 与 `L2BookSnapshot` | endpoint 订阅范围绑定现货或 USD-M Instrument；没有来源时间时明确保留缺失位。 |
| Spot / USD-M diff depth | `e`, `E`, `s`, `U`, `u`, `b[][price, quantity]`, `a[][price, quantity]` | `C3/C4/C5` 与 `L2BookDelta`；`AI:sequence`（`U..u` 连续性） | `s` 只在已绑定的产品流内解析；只有 `U <= lastUpdateId + 1 <= u` 才接受，否则发布 gap 并等待新 snapshot。 |
| USD-M `markPriceUpdate` | `e`, `E`, `s`, `p`, `i`, `r`, `T` | `C4/C5` 与 `ReferencePrice.mark`、`ReferencePrice.index`、`FundingRatePublished` | 标记价、指数价和资金费率分别保留；不以任一项回退替代另一个。 |
| public subscription acknowledgement / reconnect | control frame、绑定 Instrument、重连边界 | `AI:session/C5` 与 `MarketDataHealthChanged.awaiting_snapshot` | control frame 先写 RawIngress；重订阅后 delta 不可改变权威 L2，直至新 snapshot。 |

### 3.6 Bybit：private order、execution、wallet、position 与 instruments-info

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| private `order.data[]` | `category`, `symbol`, `orderId`, `orderLinkId`, `side`, `orderType`, `price`, `qty`, `timeInForce`, `orderStatus`, `leavesQty`, `cumExecQty`, `cumExecValue`, `avgPrice`, `cumExecFee`, `createdTime`, `updatedTime`, `reduceOnly`, `closeOnTrigger`, `positionIdx`, `isLeverage`, `placeType` | `C8/C4`（普通订单）；`C11/C13`（positionIdx/isLeverage）；`U:attached-algo`（closeOnTrigger）；`U:margin-mode`（未知 position mode）；`RE:order-detail`（placeType） | 订单更新不会直接入账。 |
| private `order.data[]` | `triggerPrice`, `triggerDirection`, `triggerBy`, `takeProfit`, `stopLoss`, `tpTriggerBy`, `slTriggerBy`, `tpslMode`, `tpLimitPrice`, `slLimitPrice`, `trailingValue`, `activePrice`, `stopOrderType` | `U:attached-algo` | 条件、TP/SL、trailing 均无首波语义。 |
| private `order.data[]` | `rejectReason`, `cancelType`, `smpType`, `smpGroup`, `smpOrderId`, `blockTradeId` | `C8`（rejectReason 经 canonical mapping）；`U:stp`（smp*）；`RE:order-detail`（其余） | 原始错误保留，核心只消费 CanonicalRejectReason。 |
| private `execution.data[]` | `category`, `symbol`, `orderId`, `orderLinkId`, `execId`, `side`, `orderType`, `execType`, `execPrice`, `execQty`, `execValue`, `execFee`, `feeRate`, `feeCurrency`, `isMaker`, `execTime`, `isLeverage`, `closedSize`, `seq`, `extraFees`, `execPnl`, `markPrice`, `indexPrice`, `underlyingPrice`, `leavesQty`, `orderPrice`, `orderQty`, `stopOrderType`, `createType` | `C9/C4`（身份、qty/price/fee/PnL/liquidity/time）；`AI:sequence`（seq）；`RE:execution-detail`（value/rate/mark/index/underlying/leaves/order*）；`U:attached-algo`（stopOrderType）；`U:enum`（未知 execType） | `execId` 是唯一 Fill 身份；经济事实按它去重。 |
| private `wallet.data[]` | `accountType`, `accountIMRate`, `accountMMRate`, `totalEquity`, `totalWalletBalance`, `totalMarginBalance`, `totalAvailableBalance`, `totalPerpUPL`, `totalInitialMargin`, `totalMaintenanceMargin`, `coin[].coin`, `equity`, `walletBalance`, `availableToWithdraw`, `availableToBorrow`, `borrowAmount`, `accruedInterest`, `totalOrderIM`, `totalPositionIM`, `totalPositionMM`, `unrealisedPnl`, `cumRealisedPnl`, `locked`, `marginCollateral`, `collateralSwitch` | `C10/C12/C13`（余额、保证金、抵押品资格）；`RE:account-detail`（展示性合计） | 以明确 account/coin scope 形成完整快照或 absolute observed。 |
| private `position.data[]` | `category`, `symbol`, `side`, `size`, `positionIdx`, `positionValue`, `entryPrice`, `markPrice`, `liqPrice`, `bustPrice`, `leverage`, `positionIM`, `positionMM`, `takeProfit`, `stopLoss`, `trailingStop`, `unrealisedPnl`, `cumRealisedPnl`, `createdTime`, `updatedTime`, `tradeMode`, `autoAddMargin`, `positionStatus`, `adlRankIndicator`, `isReduceOnly`, `seq`, `mmrSysUpdatedTime`, `leverageSysUpdatedTime` | `C11/C12/C4`（真实持仓/风险/时间）；`U:attached-algo`（TP/SL/trailing）；`U:margin-mode`（autoAddMargin/未知 tradeMode）；`AI:sequence`（seq）；`RE:position-detail`（其余） | mode 不是可默认推断的 Adapter 选项。 |
| `instruments-info.list[]` | `category`, `symbol`, `baseCoin`, `quoteCoin`, `settleCoin`, `contractType`, `status`, `launchTime`, `deliveryTime`, `priceScale`, `leverageFilter.minLeverage`, `leverageFilter.maxLeverage`, `leverageFilter.leverageStep`, `priceFilter.minPrice`, `priceFilter.maxPrice`, `priceFilter.tickSize`, `lotSizeFilter.maxOrderQty`, `lotSizeFilter.minOrderQty`, `lotSizeFilter.qtyStep`, `lotSizeFilter.maxMktOrderQty`, `lotSizeFilter.minNotionalValue`, `unifiedMarginTrade`, `fundingInterval`, `copyTrading`, `forbidUplWithdrawal` | `C6/C7/C13`（身份/规则/线性账户资格）；`U:product`（非 spot/linear）；`RE:rule-detail`（交割/copy 等） | Profile 仅在目标产品、账户和环境都匹配时可激活。 |
| `instruments-info.list[]` | `optionsType`, `innovation`, `riskParameters`, `preListingInfo`, `stTag`, `marginTrading` | `U:product`（options）；`RE:rule-detail`（其余） | 不创建跨产品的 optional core 字段。 |

### 3.7 Bybit：公共 orderbook、ticker 与 instruments-info

| 目标消息 | 字段 | 处置 | 原因 |
|---|---|---|---|
| `instruments-info.result.list[]` | `category`, `symbol`, `status`, `contractType`, `settleCoin`, `priceFilter.tickSize` | `C6/C7` 与 `InstrumentDefinitionObserved` | 仅接受 BTCUSDT spot 与 USDT LinearPerpetual；规则仍需通过配置屏障激活。 |
| public `orderbook.{depth}.BTCUSDT` | `topic`, `type`, `ts`, `cts`, `data.s`, `data.b[][price,size]`, `data.a[][price,size]`, `data.u`, `data.seq` | `C3/C4/C5` 与 `L2BookSnapshot` / `L2BookDelta`；`AI:sequence`（`u`）；`C3` cross sequence（`seq`） | snapshot 重置本地簿；不连续 delta、删除当前最优价或解析失败进入 gap，直至新 snapshot。 |
| linear public `tickers.BTCUSDT` | `ts`, `cs`, `data.symbol`, `markPrice`, `indexPrice`, `fundingRate`, `nextFundingTime` | `C4/C5` 与 `ReferencePrice.mark`、`ReferencePrice.index`、`FundingRatePublished`；`C3` cross sequence（`cs`） | mark、index 和 funding 分别保留；接受数字或数字字符串的 funding time。 |
| public ticker 其它字段 | `lastPrice`, `bid1Price`, `ask1Price`, `openInterest`, `volume24h`, `deliveryTime`, pre-listing / futures 字段 | `RE:market-detail`；`U:product`（非目标产品） | 不用展示值替代 L2、mark、index 或 funding 事实。 |
| subscribe acknowledgement / reconnect | `success`, `op`, `req_id`, `retCode`, `retMsg` 与新的订阅边界 | `AI:session/C5` 与 `MarketDataHealthChanged.awaiting_snapshot` | control frame 先写 RawIngress；新订阅前不得用旧 delta 恢复健康。 |

### 3.8 Hyperliquid：首期协议合同

范围、单位、身份、消息入口、样本来源及必须补查项统一见
[协议合同](research/2026-11-02-hyperliquid-protocol-contract.md)，签名/分页细节见
[固定 SDK 与历史依据](research/2026-11-02-hyperliquid-signing-history.md)。
以下是 **02–06 的目标映射**，不是当前 decoder 已接受字段的声明。
05 的执行实现与实际离线证据见[本地票](../.scratch/hyperliquid-adapter/issues/05-orders-private-facts.md)：
订单、独立 Fill、逐仓杠杆与有 bootstrap 引用的账户增量已接共享 VenueAdapter；
spot 余额另需批准的 token index→Asset 映射。资金费/强制执行缺完整身份时输出安全故障，
所有历史覆盖与 Unknown 闭合仍留给 06；本表不授予这些未完成能力。
表中逗号分隔字段逐个适用处置；括号内对象只是容器，下面列全所用成员。
没有值、null、未知 enum 均不自动变成零/false/USDC。所有输入保留 C5 原文；
新增未知字段留 RE，改变经济/风险语义则停用该范围并对账。

| 目标消息 | 字段 | 处置 | 单位、身份与缺失处理 |
|---|---|---|---|
| REST/WS 请求/包络 | `type`, `method`, `subscription`, `channel`, `data`, `user`, `coin`, `dex`, `id` | AI:route/session；C1/C2；C6（coin 解析） | 显式固定 Venue/环境/资金账户；dex 只接受标准空 dex；私有 user 不回退到 agent；容器类型与关联不符拒绝 |
| WS 订阅 | `nSigFigs`, `mantissa`, `isSnapshot` | AI:subscription/coverage | 首期 l2Book 不请求聚合精度；isSnapshot 不等于全历史覆盖；缺标记不可声称 bootstrap 完成 |
| REST 请求范围 | `startTime`, `endTime`, `aggregateByTime`, `oid`, `tokenId` | AI:query/identity | inclusive ms 窗口；成交不聚合；保留每页边界与截断证据；oid 可为原 oid/CLOID |
| REST response/WS 控制 | `status`, `response.type`, `response.data.statuses`, `error` | AI:protocol；C14（transport 结果另生成） | 先逐项验证响应关联；错误不冒充空事实；开始写入后缺响应=Unknown |
| `meta` | `universe`, `marginTables`, `collateralToken` | AI:container；C6/C7/C12（成员） | 完整 metadata scope，collateralToken 必须解析实际 Asset |
| `meta.universe[]` | `name`, `szDecimals`, `maxLeverage`, `marginTableId`, `onlyIsolated`, `marginMode`, `isDelisted` | C6/C7（name/szDecimals/isDelisted）；C12/C13（margin 字段） | name+下标绑定产品；数量十进制位；maxLeverage 是上限非实际杠杆；缺账户模式不推定逐仓 |
| `meta.marginTables[]` | `[id, table]`, `table.description`, `table.marginTiers`, `marginTiers[].lowerBound`, `marginTiers[].maxLeverage` | AI:rule-join（id）；RE:rule-label（description）；C12（tiers） | lowerBound 为结算名义金额；档位/规则需完整且版本化；不拿最大杠杆推断完整维持保证金规则 |
| `spotMeta` | `tokens`, `universe` | AI:container | 完整产品/资产范围；未知 token 不自动注册成 BTC/ETH |
| `spotMeta.tokens[]` | `name`, `index`, `tokenId`, `szDecimals`, `weiDecimals`, `isCanonical`, `evmContract`, `fullName`, `deployerLabel`, `deployerTradingFeeShare` | C6/C7（name/index/tokenId/szDecimals）；RE:asset-evidence（其余） | weiDecimals 不自动激活账本单位；显示/部署者字段不证明经济等价；deployer share 不是另加实际 Fill 费用 |
| `tokens[].evmContract` | `address`, `evm_extra_wei_decimals` | RE:asset-evidence | 地址/链证据，不按符号归并；null 不填造桥接身份 |
| `spotMeta.universe[]` | `name`, `tokens[]`, `index`, `isCanonical` | C6/C7（name/tokens/index）；RE:asset-evidence（isCanonical） | tokens 按 base/quote 顺序，action asset=10000+pair index；不等于 token index |
| `tokenDetails` | `name`, `maxSupply`, `totalSupply`, `circulatingSupply`, `szDecimals`, `weiDecimals`, `midPx`, `markPx`, `prevDayPx`, `genesis`, `deployer`, `deployGas`, `deployTime`, `seededUsdc`, `nonCirculatingUserBalances`, `futureEmissions`, `fullName`, `evmContract`, `deployerTradingFeeShare` | RE:asset-due-diligence | 只作资产核查，不递归解码 genesis/分配为权威事实；请求 tokenId 外绑；不能据供应/显示价格授予规则或包装资产资格 |
| `tokenDetails` nested | `genesis.userBalances[][address,amount]`, `genesis.existingTokenBalances[]`, `nonCirculatingUserBalances[][address,amount]` | RE:asset-due-diligence | 全部只留证据，不形成账户快照；existingTokenBalances 内部结构未用于本期能力，后续消费前补合同 |
| `l2Book` REST/WS | `coin`, `time`, `levels`, `levels[][i].px`, `levels[][i].sz`, `levels[][i].n` | C6/C4/C5；C: L2BookSnapshot（px/sz）；RE:order-count（n） | ms、quote/base、base；买/卖双数组；最多每侧8档及截断；无源序号，只替换覆盖范围；坏/空边不能补造 BBO |
| `trades` / `recentTrades` | `coin`, `side`, `px`, `sz`, `hash`, `time`, `tid`, `users[]` | C: MarketTrade（coin/side/px/sz/time/tid）；RE:trade-evidence（hash/users） | B=buy/A=sell；键(time,coin,tid)，非账户 Fill；未知方向拒绝，users 不作策略归属 |
| `activeAssetCtx` | `coin`, `ctx`, `ctx.markPx`, `ctx.oraclePx`, `ctx.funding`, `ctx.openInterest`, `ctx.dayNtlVlm`, `ctx.prevDayPx`, `ctx.midPx`, `ctx.premium`, `ctx.impactPxs`, `ctx.dayBaseVlm` | C: ReferencePrice（markPx/oraclePx）；RE:market-detail（funding 与其余） | 04 实现分离 mark/index，源时间 absent；ctx 无资金费所属时点，funding 保留证据，不用接收时间伪造费率时点；mid 不作回退 |
| `fundingHistory` | `coin`, `fundingRate`, `premium`, `time` | C: FundingRatePublished（coin/fundingRate/time）；RE:market-detail（premium） | 04 实现精确 ppm 与 ms→ns；费率不是百分数或付款，精度不足拒绝并撤销对应行情资格，不舍入 |
| 下单 action | `type`, `orders`, `grouping`, `builder` | AI:codec（type/orders）；U:attached-algo（非na grouping）；U:builder（builder） | 首期不含 builder 或归因审批；只接受 grouping=na，不复制参考项目默认 |
| `orders[]` | `a`, `b`, `p`, `s`, `r`, `t`, `c`, `t.limit.tif` | AI:transport/C8 | asset index、isBuy bool、精确价格/数量文本、reduceOnly bool、CLOID；tif仅Gtc/Ioc/Alo；r仅支持永续；trigger/其它TIF拒绝 |
| 撤单 action | `type`, `cancels`, `cancels[].a`, `cancels[].o`, `cancels[].asset`, `cancels[].cloid` | AI:transport/C8 | cancel 用a/o；cancelByCloid 用asset/cloid；固定账户及原订单身份；未知结果不换号重发 |
| 签名包络 | `nonce`, `vaultAddress`, `expiresAfter`, `signature.r`, `signature.s`, `signature.v` | AI:signing（不入 RawIngress/fixture 的签名材料）；U:product（vault） | nonce/expiry ms、u64；固定 SDK 序列化；主账户 vaultAddress=null；子账户显式绑定另验；真实私钥/签名不落盘 |
| action statuses[] | `resting.oid`, `resting.cloid`, `filled.oid`, `filled.cloid`, `filled.totalSz`, `filled.avgPx`, `error`, `success`（撤单字符串） | C8/AI:response | filled aggregate 只证明报告量/均价，不能代替 C9；逐项 error 不改为全批拒绝；success 撤单仍核对迟到成交 |
| `orderStatus` | `status`, `order.order`, `order.status`, `order.statusTimestamp` | AI:lookup（外status）；C8/C4（内订单） | status=unknownOid 保持 unresolved；已知内status白名单见签名/历史依据，未知停止映射 |
| `orderUpdates` / `historicalOrders` / `openOrders` / `frontendOpenOrders` 的 order | `coin`, `side`, `limitPx`, `sz`, `oid`, `timestamp`, `origSz`, `cloid`, `status`, `statusTimestamp`, `orderType`, `reduceOnly`, `isPositionTpsl`, `isTrigger`, `triggerCondition`, `triggerPx`, `tif`, `children` | C8/C4（普通订单及时间）；U:attached-algo（trigger/positionTpsl/children）；RE:order-detail（非触发条件文本） | origSz/剩余sz可精确相减才形成报告累计；openOrders简化行缺origSz时只作存在证据；缺cloid需已持久oid绑定；不猜订单类型 |
| `userFills` / `userFillsByTime` / `userEvents.fills[]` | `coin`, `px`, `sz`, `side`, `time`, `startPosition`, `dir`, `closedPnl`, `hash`, `oid`, `crossed`, `fee`, `tid`, `feeToken`, `builderFee`, `cloid`, `twapId` | C9/C4（交易/费用/身份/时间）；RE:fill-evidence（startPosition/hash/builderFee）；AI:order-binding（cloid）；U:order-kind（twapId非null）；C: forced 候选（dir） | 同账户产品下(time,tid,oid)复合身份；fee负数返佣；crossed为taker；builderFee已含fee；未知feeToken拒绝，不从累计量/余额差造Fill |
| fill `liquidation` | `method`, `markPx`, `liquidatedUser` | C: VenueForcedExecution 候选（完整执行时）；RE:liquidation-evidence | method market/backstop；不据backstop独自断定ADL；markPx不是实际成交价；归属/金额不足保持break |
| `userEvents.liquidation` | `lid`, `liquidator`, `liquidated_user`, `liquidated_ntl_pos`, `liquidated_account_value` | RE:liquidation-evidence；AI:reconciliation | 账户级摘要不构造订单/Fill；nt l/account value为金额而非成交数量；启动配置/经济核对 |
| `userEvents.nonUserCancel[]` | `coin`, `oid` | AI:reconciliation；C8候选 | 仅触发原身份查询，不臆造终态累计成交量 |
| `userFundings` / `userFills` / `userNonFundingLedgerUpdates` | `isSnapshot`, `user`, `fundings`, `fills`, `nonFundingLedgerUpdates` | AI:scope/bootstrap（包络）；成员独立映射 | 初始集不是无界历史；缺user或账户不符拒绝；空集不能证明旧Unknown不存在 |
| `userFunding` / `userEvents.funding` / `fundings[]` | `time`, `hash`, `delta.type`, `delta.coin`, `delta.usdc`, `delta.szi`, `delta.fundingRate`, `delta.nSamples`；WS直接`coin`, `usdc`, `szi`, `fundingRate` | C: FundingSettlement（coin/usdc/time及可证明身份）；RE:funding-evidence（hash/szi/rate/nSamples）；AI:kind（type） | USDC有符号金额；复合时间/品种/账户身份及修订待06核实；不能把hash硬截断为venue_bill_id或按rate推造款项 |
| `userNonFundingLedgerUpdates` 行 | `time`, `hash`, `delta.type`, `delta` | C4；RE:ledger-evidence；AI:reconciliation | 未实现transfer/deposit/withdraw等delta逐项经济映射前保持Unsupported/安全锁存；未知variant不静默忽略、不把它当Fill |
| ledger `deposit` / `withdraw` | `usdc`；withdraw 的 `nonce`, `fee` | RE:ledger-evidence；AI:reconciliation | USDC金额及费用/动作关联；当前不开放资金动作，但实际外部变化必须核对 |
| ledger `internalTransfer` / `subAccountTransfer` | `usdc`, `user`, `destination`；internal 的 `fee` | RE:ledger-evidence；AI:reconciliation | 资金地址和金额，不推断 VirtualPortfolio 所有权 |
| ledger `liquidation` | `accountValue`, `leverageType`, `liquidatedPositions`, `liquidatedPositions[].coin`, `liquidatedPositions[].szi` | RE:liquidation-evidence；AI:reconciliation | isolated accountValue是逐仓范围；无成交价/费用不生成ForcedExecution；Cross模式撤资格 |
| ledger `vaultCreate` / `vaultDeposit` / `vaultDistribution` | `vault`, `usdc` | RE:ledger-evidence；U:product | 非支持资金范围；保留证据并锁存 |
| ledger `vaultWithdraw` | `vault`, `user`, `requestedUsd`, `commission`, `closingCost`, `basis`, `netWithdrawnUsd` | RE:ledger-evidence；U:product | 不自动入本期经济账；不能忽略账户实际变化 |
| ledger `vaultLeaderCommission` | `user`, `usdc` | RE:ledger-evidence；U:product | 同上 |
| ledger `spotTransfer` | `token`, `amount`, `usdcValue`, `user`, `destination`, `fee` | RE:ledger-evidence；AI:reconciliation | token金额与USD估值分离，外部动作需核对；不创造Fill |
| ledger `accountClassTransfer` / `spotGenesis` / `rewardsClaim` | accountClass 的 `usdc`, `toPerp`；spotGenesis 的 `token`, `amount`；rewardsClaim 的 `amount` | RE:ledger-evidence；AI:reconciliation | 不以账户类间转移代替策略资金划拨；缺真实Asset/身份保持缺口 |
| `clearinghouseState` REST/WS | `user`, `dex`, `clearinghouseState`, `assetPositions`, `marginSummary`, `crossMarginSummary`, `crossMaintenanceMarginUsed`, `withdrawable`, `time` | C4/C10/C11/C12（有scope成员）；AI:container（user/dex/wrapper）；U:margin-mode（实际cross） | REST顶层和WS包络分别拆解；withdrawable不等于spot可用余额；缺真实逐仓范围不伪装完整快照 |
| margin summary | `accountValue`, `totalNtlPos`, `totalRawUsd`, `totalMarginUsed` | C12候选；RE:account-summary | USDC金额但有账户汇总scope；不据差额推导单portfolio/单逐仓可用资金 |
| `assetPositions[]` | `type`, `position`, `position.coin`, `position.szi`, `position.entryPx`, `position.positionValue`, `position.unrealizedPnl`, `position.returnOnEquity`, `position.liquidationPx`, `position.marginUsed`, `position.maxLeverage`, `position.cumFunding.allTime`, `position.cumFunding.sinceOpen`, `position.cumFunding.sinceChange` | C11/C12（coin/szi/entryPx/unrealizedPnl/liquidationPx/marginUsed）；C13（type）；RE:position-detail（其余） | szi有符号base数量；entry/liquidation null=未知；cumFunding累计非独立资金流水，不重复入账；type只接受oneWay |
| position/activeAssetData `leverage` | `type`, `value`, `rawUsd` | C13（type/value）；C12候选（rawUsd） | type=isolated才符合首期；rawUsd原scope保留，缺失不能补0；value倍数不是风险模型 |
| `activeAssetData` | `user`, `coin`, `maxTradeSzs[]`, `availableToTrade[]`, `markPx` | AI:scope；RE:account-capacity；C:ReferencePrice候选（REST markPx） | Venue方向性容量观察，不替代本地风控/真实资产余额；上列leverage单独映射；markPx缺失不回退 |
| `spotClearinghouseState` / `spotState` | `user`, `spotState`, `balances`, `balances[].coin`, `balances[].token`, `balances[].hold`, `balances[].total`, `balances[].entryNtl` | AI:scope/container；C10（coin/token/hold/total）；RE:cost-display（entryNtl） | 实际token Asset金额，total-hold仅在完整普通spot scope中计算available；不与perp USDC汇总/回退，不重建虚假现货仓位 |
| `userAbstraction` / `userRole` | 模式字符串；`role`, `data.user`, `data.master` | C13候选；AI:authority-evidence | 仅default/disabled候选且仍须实际逐仓核对；unifiedAccount/portfolioMargin/dexAbstraction及未知模式拒绝；role区分user/agent/subAccount，不等于权限证明；can_withdraw=false不能凭默认bool伪造 |
| `userRateLimit` | `cumVlm`, `nRequestsUsed`, `nRequestsCap`, `nRequestsSurplus` | AI:limit | Venue账户额度观察，不覆盖同IP聚合/其它进程；缺失不设置无限额度 |
| 非首期请求/字段 | `modify`, `batchModify`, `trigger`, `twapOrder`, `scheduleCancel`, HIP-3/HIP-4、vault、bridge/transfer/withdraw 签名动作、builder审批 | U:order-kind/product/authority | 不编码、不发送；意外观察真实外部资金/模式变化时保留RawEvidence并锁存安全问题，不能因为不支持而丢掉变化 |

## 4. CapabilityProfile 证据登记

Profile 是一项不可变配置事实，键为
`Venue + Environment + ExchangeAccount + ProductScope + CapabilityVersion + RulesVersion + ConfigVersion`。
同一个 Venue 的现货、线性、Demo/Testnet 和生产账户不能互相继承资格。

Hyperliquid 当前只有本节前的协议合同及样本，没有运行时 Profile、签名/发送实现或 Testnet
资格；02–08 的实现与验收完成前不加入已实现能力表。

| Profile candidate | 精确范围 | 文档证据 | 实现/资格证据 | 允许状态 |
|---|---|---|---|---|
| `okx-demo-spot-v1` | OKX + Demo + 指定 ExchangeAccount + BTC-USDT SPOT | §1.1 OKX orders/account/instruments | `src/adapters/okx/okx_order_entry.zig` 的固定订单编码和 tests；`src/adapters/okx/okx_private_reconciliation.zig` 的 RawIngress/bootstrap tests | `demo_qualified` 仅在单独的 Demo 证据通过后；生产一律 `U:authority`。 |
| `okx-demo-linear-v1` | OKX + Demo + 指定 ExchangeAccount + BTC-USDT-SWAP isolated | §1.1 OKX orders/positions/instruments | 同上；只声明明确测试过的 limit/IOC/FOK/post-only、native amend、批量和 VenueReduceOnly | 不得扩展到 cross、hedge、auto-add margin 或其它 instrument。 |
| `binance-spot-testnet-v1` | Binance Spot Testnet + 指定账户 + BTC-USDT | §1.1 Spot messages/exchangeInfo；§3.5 public depth | `src/adapters/binance/binance_market_feed.zig` 的官方 fixture、RawIngress 与 MarketFeedAdapter contract；`src/adapters/binance/binance_venue_adapter.zig` 与 `src/adapters/binance/binance_private_reconciliation.zig` 的私有 seam、分页 bootstrap、去重和显式 Testnet/no-withdraw/notional guard tests；`src/testing/acceptance/venues/binance_testnet_acceptance.zig` 的前后清洁状态与证据范围 tests | `testnet_run`；不授予生产交易或 Linux 性能资格。 |
| `binance-usdm-testnet-v1` | Binance USD-M Testnet + 指定账户 + BTCUSDT perpetual | §1.1 USD-M messages/exchangeInfo；§3.5 public depth / mark price | 同上，含线性 L2、mark/index/funding，以及 USD-M private order/account 定向 tests；相同 TestnetRun guard 与清洁状态证据 | `testnet_run`；不授予生产交易或 Linux 性能资格。 |
| `bybit-spot-testnet-v1` | Bybit Testnet + 指定账户 + BTCUSDT spot | §1.1 Bybit private/instrument messages；§3.7 public orderbook | `src/adapters/bybit/bybit_market_feed.zig` 的官方 V5 fixture、RawIngress、序列与 MarketFeedAdapter contract tests；`src/adapters/bybit/bybit_venue_adapter.zig` / `src/adapters/bybit/bybit_private_reconciliation.zig` 的 canonical command、order/fill 去重、完整 bootstrap/absolute observed 与共享 Adapter contract tests；`src/testing/acceptance/venues/bybit_testnet_acceptance.zig` 的显式 Testnet/no-withdraw/清洁状态 guard | `official_confirmed`；未运行真实 Testnet 前不授予生产或 Linux 资格。 |
| `bybit-linear-testnet-v1` | Bybit Testnet + 指定账户 + BTCUSDT linear | §1.1 Bybit private/instrument messages；§3.7 public orderbook/ticker | 同上，含线性 mark/index/funding、cross sequence、linear position、VenueReduceOnly 与 aggregate Testnet/replay/isolation evidence guard | `official_confirmed`；未运行真实 Testnet 前不授予生产或 Linux 资格。 |

每个未来 `demo_qualified` / `testnet_qualified` Profile 必须附带：资料版本/URL、fixture hash、
账户与环境证明、权限（无提现）、完整 bootstrap、限流/分页边界、RawIngress 可写证明、
contract-suite 结果，以及显式 live cleanup 记录。缺任何一项时状态只能是
`official_confirmed`，且 `OrderCommand` 按 `U:authority` 拒绝。

## 5. 审核检查

- 不允许新增未归类的目标消息字段；先更新本表和 Profile 证据，再写 codec。
- 不允许使用百分比、覆盖率或“已映射字段数量”作为完成标准。
- `Canonical` 映射必须引用 C1--C14；无类型/单位/必填/缺失策略的映射无效。
- `Unsupported` 必须引用本文件的 `U:*` 规则；实现不得把它替换为 Adapter fallback。
- Adapter 资料/fixture 变化必须重新审阅相应 Profile；重审不自动升级交易权限。
- 本任务只建立处置和证据输入；不实现 #8 的共享事件/Adapter 契约，也不实现 Binance 或 Bybit。
