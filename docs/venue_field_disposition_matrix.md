# Venue 字段处置矩阵与 CapabilityProfile 证据

> 状态：已审核的设计输入；不授予任何交易权限
> 更新：2026-08-28
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
| Binance | User Data Stream `executionReport`、`outboundAccountPosition`、`balanceUpdate`；`exchangeInfo` | USD-M User Data Stream `ORDER_TRADE_UPDATE`、`ACCOUNT_UPDATE`；`exchangeInfo` | [Spot user stream](https://developers.binance.com/docs/binance-spot-api-docs/user-data-stream)、[Spot exchange info](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/general-endpoints#exchange-information)、[USD-M user stream](https://developers.binance.com/docs/derivatives/usds-margined-futures/user-data-streams/Event-Order-Update)、[USD-M exchange info](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Exchange-Information) |
| Bybit | v5 private `order`、`execution`、`wallet`；`instruments-info?category=spot` | v5 private `order`、`execution`、`position`、`wallet`；`instruments-info?category=linear` | [order](https://bybit-exchange.github.io/docs/v5/websocket/private/order)、[execution](https://bybit-exchange.github.io/docs/v5/websocket/private/execution)、[wallet](https://bybit-exchange.github.io/docs/v5/websocket/private/wallet)、[position](https://bybit-exchange.github.io/docs/v5/websocket/private/position)、[instruments](https://bybit-exchange.github.io/docs/v5/market/instrument) |

仅限 `SPOT`、`SWAP` / USD-M、Bybit `spot` / `linear`。期权、交割合约、组合保证金和
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
| C3 | `EventEnvelope.source` / `source_sequence` | stream identity + `u64` | 每个 REST/WS 来源 | 生成 Adapter local sequence；断档使投影无效。 |
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

### 3.5 Bybit：private order、execution、wallet、position 与 instruments-info

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

## 4. CapabilityProfile 证据登记

Profile 是一项不可变配置事实，键为
`Venue + Environment + ExchangeAccount + ProductScope + CapabilityVersion + RulesVersion + ConfigVersion`。
同一个 Venue 的现货、线性、Demo/Testnet 和生产账户不能互相继承资格。

| Profile candidate | 精确范围 | 文档证据 | 实现/资格证据 | 允许状态 |
|---|---|---|---|---|
| `okx-demo-spot-v1` | OKX + Demo + 指定 ExchangeAccount + BTC-USDT SPOT | §1.1 OKX orders/account/instruments | `src/okx_order_entry.zig` 的固定订单编码和 tests；`src/okx_private_reconciliation.zig` 的 RawIngress/bootstrap tests | `demo_qualified` 仅在单独的 Demo 证据通过后；生产一律 `U:authority`。 |
| `okx-demo-linear-v1` | OKX + Demo + 指定 ExchangeAccount + BTC-USDT-SWAP isolated | §1.1 OKX orders/positions/instruments | 同上；只声明明确测试过的 limit/IOC/FOK/post-only、native amend、批量和 VenueReduceOnly | 不得扩展到 cross、hedge、auto-add margin 或其它 instrument。 |
| `binance-spot-testnet-v1` | Binance Spot Testnet + 指定账户 + BTC-USDT | §1.1 Spot messages/exchangeInfo | 仅资料证据；尚无 Adapter fixture、RawIngress、contract 或 live-cleanup evidence | `official_confirmed`，所有发送仍 `U:authority`。 |
| `binance-usdm-testnet-v1` | Binance USD-M Testnet + 指定账户 + BTCUSDT perpetual | §1.1 USD-M messages/exchangeInfo | 仅资料证据；尚无 Adapter/qualification evidence | `official_confirmed`，所有发送仍 `U:authority`。 |
| `bybit-spot-testnet-v1` | Bybit Testnet + 指定账户 + BTCUSDT spot | §1.1 Bybit private/instrument messages | 仅资料证据；尚无 Adapter/qualification evidence | `official_confirmed`，所有发送仍 `U:authority`。 |
| `bybit-linear-testnet-v1` | Bybit Testnet + 指定账户 + BTCUSDT linear | §1.1 Bybit private/instrument messages | 仅资料证据；尚无 Adapter/qualification evidence | `official_confirmed`，所有发送仍 `U:authority`。 |

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
