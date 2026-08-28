# Venue message inventory — official primary sources

**Research access date:** 2026-08-28.  This is an input inventory for Issue
#7's per-field disposition matrix, not a claim that any account has passed
qualification.  Exchange documents change independently; the implementation
must retain the documentation revision/access date and re-check the applicable
environment and account before enabling a `CapabilityProfile`.

## Scope and reading rule

The target is the *current* first-scope protocol surface only:

| Family | Included | Excluded from the first model |
| --- | --- | --- |
| Product | spot; USDT-settled linear perpetual | inverse, delivery futures, options, margin borrowing as a product, pre-market contracts |
| Private order | normal place/amend/cancel lifecycle | algorithmic orders, OCO, attached TP/SL, trailing stop, STP |
| Execution | order-state reports and individual fills | derived PnL/accounting that lacks a unique execution identity |
| Account | balances, positions, margin/equity as an absolute observation or bootstrap snapshot | a websocket delta incorrectly named a complete snapshot |

For every row below, the linked **official response-parameter table is the
complete field inventory** for the named message as observed on the access
date.  The compact fields in this note identify the facts that the disposition
matrix must decide; they are not a replacement for the linked complete table.
All decimal strings must cross the seam as losslessly parsed, checked integer
amounts/prices/quantities under the active instrument rules.

## Official messages and field-table references

| Venue / qualified product | Current message or endpoint | Official complete field table | Matrix-critical fields and facts |
| --- | --- | --- | --- |
| OKX spot, linear perpetual (`SWAP` with `ctType=linear`) | Private WS `orders` | [WS / Order channel](https://www.okx.com/docs-v5/en/#order-book-trading-ws-orders-channel) | Identity: `ordId`, `clOrdId`; product: `instType`, `instId`; command/state: `side`, `ordType`, `state`, `tdMode`, `posSide`; quantities/prices: `sz`, `px`, `accFillSz`, `fillSz`, `fillPx`, `avgPx`; fact/time: `tradeId`, `fillTime`, `cTime`, `uTime`; economics: `fillFee`, `fillFeeCcy`, `fee`, `feeCcy`, `rebate`, `rebateCcy`, `fillPnl`, `pnl`; evidence/error: `reqId`, `amendResult`, `code`, `msg`.  `accFillSz` is cumulative; a present `tradeId` identifies a fill; see the channel's duplicate guidance. |
| OKX spot, linear perpetual | Private WS `fills` (supplemental execution stream) | [WS / Fills channel](https://www.okx.com/docs-v5/en/#order-book-trading-ws-fills-channel) | `instId`, `fillSz`, `fillPx`, `side`, `ts`, `ordId`, `clOrdId`, `tradeId`, `execType`, `count`.  It can aggregate taker matches and is expressly only partial; it cannot be the sole authoritative execution source. |
| OKX spot, linear perpetual | Private WS `balance_and_position`; private WS `positions`; REST bootstrap account/positions | [Balance and position channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-channel-balance-and-position-channel), [Positions channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-channel-positions-channel), [Get balance](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-balance), [Get positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions) | Balance/account values include `adjEq`, `details[].ccy`, `eq`, `cashBal`, `availBal`, `frozenBal`, `upl`, `isoEq`, `mgnRatio`, `imr`, `mmr`, `uTime`; positions carry `posId`, `instId`, `instType`, `mgnMode`, `posSide`, `pos`, `availPos`, `avgPx`, `markPx`, `upl`, `uplRatio`, `margin`, `imr`, `mmr`, `lever`, `liqPx`, `tradeId`, `uTime`.  Treat WS deliveries as observations; obtain the declared complete baseline through REST. |
| OKX spot, linear perpetual | Public REST `GET /api/v5/public/instruments` and public WS `instruments` | [Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments), [Public instruments channel](https://www.okx.com/docs-v5/en/#public-data-websocket-public-instruments-channel) | Select `instType=SPOT` or `SWAP`; use `instId`, `baseCcy`, `quoteCcy`, `settleCcy`, `ctType`, `ctVal`, `ctMult`, `tickSz`, `lotSz`, `minSz`, `maxLmtSz`, `maxMktSz`, `state`, `expTime`, `listTime`, and `ruleType` as versioned instrument/rule evidence. `ctType=linear` qualifies the linear contract, not the symbol text alone. |
| Binance Spot | User-data `executionReport` | [Spot user-data stream](https://developers.binance.com/en/docs/products/spot/user-data-stream), [official Spot WS schemas](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/ws-streams/~schemas) | Envelope `e`, `E`; identity `i` (order), `c`/`C` (client/replaced client), `t` (trade), `I` (execution); product `s`; order `S`, `o`, `f`, `q`, `p`, `P`, `F`, `g`, `x`, `X`, `r`; execution `l`, `z`, `L`, `Y`, `Z`, `n`, `N`, `m`, `M`, `O`, `T`, `W`. Conditional fields (`d`, `D`, `j`, `J`, `v`, `A`, `B`, `u`, `U`, `Cs`, `pl`, `pL`, `pY`, `Q`, `b`, `a`, `k`, `uS`) require a documented applicability/missing rule rather than an invented default. |
| Binance Spot | User-data `outboundAccountPosition`, `balanceUpdate`; REST `exchangeInfo` | [Spot user-data stream](https://developers.binance.com/en/docs/products/spot/user-data-stream), [Exchange information](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/general) | Balances: `B[].a` asset, `f` free, `l` locked; delta notice `a`, `d`, `T`.  Product response supplies symbol status, base/quote assets and precision plus `filters`, order types, permissions and allowed STP modes.  `permissions=SPOT` and `symbolStatus=TRADING` are qualification facts, not global assumptions. |
| Binance USD-M futures (USDT linear perpetual) | User-data `ORDER_TRADE_UPDATE` | [USD-M user-data stream](https://developers.binance.info/en/docs/products/derivatives-trading-usds-futures/user-data-streams), [official USD-M WS schemas](https://developers.binance.info/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/ws-streams/~schemas) | Envelope `e`, `E`, `T`; `o` contains `s`, `c`, `S`, `o`, `f`, `q`, `p`, `ap`, `sp`, `x`, `X`, `i`, `l`, `z`, `L`, `N`, `n`, `T`, `t`, `b`, `a`, `m`, `R`, `wt`, `ot`, `ps`, `cp`, `AP`, `cr`, `rp`, `pP`, `si`, `ss`, `V`, `pm`, `gtd`.  This one event provides order lifecycle and trade execution; dispatch it into separate `ExecutionReport` and unique Fill facts where `t`/execution identity exists. |
| Binance USD-M futures | User-data `ACCOUNT_UPDATE`; REST `exchangeInfo` | [USD-M user-data stream](https://developers.binance.info/en/docs/products/derivatives-trading-usds-futures/user-data-streams), [Exchange information](https://developers.binance.com/docs/derivatives/usds-margined-futures/market-data/rest-api/Exchange-Information) | `a.m` gives reason; `a.B[]` balances (`a`, `wb`, `cw`, `bc`) and `a.P[]` changed positions (`s`, `pa`, `ep`, `bep`, `cr`, `up`, `mt`, `iw`, `ps`, `ma`, `bep`) are deltas, not a full account snapshot. Product fields include `contractType`, `status`, `baseAsset`, `quoteAsset`, `marginAsset`, `pricePrecision`, `quantityPrecision`, `filters`, order types and time-in-force. Qualify only `contractType=PERPETUAL` plus the required settlement/margin asset. |
| Bybit UTA spot, linear perpetual | Private WS `order.spot`, `order.linear` | [Order private stream](https://bybit-exchange.github.io/docs/v5/websocket/private/order) | Envelope `id`, `topic`, `creationTime`; lifecycle `category`, `orderId`, `orderLinkId`, `symbol`, `side`, `orderType`, `timeInForce`, `orderStatus`, `cancelType`, `rejectReason`, `createdTime`, `updatedTime`; values `price`, `qty`, `avgPrice`, `leavesQty`, `leavesValue`, `cumExecQty`, `cumExecValue`; semantics `positionIdx`, `reduceOnly`, `closeOnTrigger`, `isLeverage`.  The table also carries TP/SL/OCO and SMP fields; classify those as Unsupported/NotApplicable for the first model rather than silently accepting them. |
| Bybit UTA spot, linear perpetual | Private WS `execution.spot`, `execution.linear` | [Execution private stream](https://bybit-exchange.github.io/docs/v5/websocket/private/execution) | Envelope `id`, `topic`, `creationTime`; identity `execId`, `orderId`, `orderLinkId`; product `category`, `symbol`; execution `execPrice`, `execQty`, `execValue`, `execType`, `execTime`, `leavesQty`, `side`, `isMaker`; economics `execFee`, `feeCurrency`, `feeRate`, `execPnl`; continuity `seq` (unique at least with `symbol`). A single message can contain several executions. |
| Bybit UTA spot, linear perpetual | Private WS `wallet`; private WS `position.linear`; REST wallet/position bootstrap | [Wallet private stream](https://bybit-exchange.github.io/docs/v5/websocket/private/wallet), [Position private stream](https://bybit-exchange.github.io/docs/v5/websocket/private/position), [Get wallet balance](https://bybit-exchange.github.io/docs/v5/account/wallet-balance), [Get position info](https://bybit-exchange.github.io/docs/v5/position) | Wallet/account: `accountType`, account IM/MM rates, total equity/wallet/margin/available values, and `coin[]` fields such as `coin`, `equity`, `walletBalance`, `locked`, order/position IM/MM, `unrealisedPnl`, `cumRealisedPnl`, borrow and collateral fields. Linear position: `symbol`, `side`, `size`, `positionIdx`, `positionValue`, `riskId`, `riskLimitValue`, `entryPrice`, `markPrice`, `leverage`, `unrealisedPnl`, `positionIM`, `positionMM`, `liqPrice`, `tradeMode`, `autoAddMargin`, `positionStatus`, timestamps and `seq`. The wallet stream explicitly supplies **no subscription snapshot**, so REST must establish the bootstrap baseline. |
| Bybit UTA spot, linear perpetual | REST `GET /v5/market/instruments-info?category=spot|linear` | [Get instruments info](https://bybit-exchange.github.io/docs/v5/market/instrument) | Response `category`, `nextPageCursor`, `list[]`; common identity/status `symbol`, `symbolId`, `status`, `baseCoin`, `quoteCoin`, timing; linear: `contractType`, `settleCoin`, `priceFilter`, `lotSizeFilter`, `leverageFilter`, `riskParameters`; spot: price/lot filters plus its spot-specific order-limit fields. Follow pagination for `linear`; the documentation states its default page can exceed the default limit. `category=linear`, `contractType=LinearPerpetual`, `status=Trading`, and settlement coin are the explicit linear-product qualification evidence. |

## CapabilityProfile qualification facts

These findings constrain the profile schema and its evidence, rather than
declaring a supported order feature from documentation alone.

| Fact | Evidence and consequence |
| --- | --- |
| Profile scope cannot be venue-global | Each protocol names product classes differently (`SPOT`/`SWAP`, Spot/USD-M, `spot`/`linear`) and account/margin semantics appear only for some products. Persist the actual `VenueIdentity`, environment, `ExchangeAccountIdentity`, product/instrument mapping, rules/config version and source links together. |
| Stream access is a qualification gate | OKX's `fills` channel is restricted to VIP4+ and omits several non-order-book execution types; a profile must record whether it is actually admitted and retain `orders`/REST reconciliation regardless.  Bybit demo supports private streams but not WS Trade; do not promote demo connectivity into production trading authority. ([OKX fills](https://www.okx.com/docs-v5/en/#order-book-trading-ws-fills-channel), [Bybit demo](https://bybit-exchange.github.io/docs/v5/demo)) |
| Client identifiers are opaque and channel-qualified | Preserve OKX `ordId`/`clOrdId`, Binance order/trade/execution identifiers, and Bybit `orderId`/`orderLinkId`/`execId` as bounded opaque venue references.  In particular, OKX fills only returns a caller ID under its documented signed-int64 condition; the normal orders channel has different `clOrdId` behaviour. |
| No WS feed alone proves a baseline | OKX orders/fills have no initial snapshot. Bybit wallet says no subscription snapshot. Binance account messages are changes/changed positions. All require profile evidence that the applicable REST bootstrap, pagination and buffered-delta ordering process was qualified before trading. |
| Ordering/dedup must be source-specific | OKX documents duplicates and dedup by `tradeId`/terminal `ordId`; Bybit `seq` can repeat across symbols, so use `seq + symbol`; Binance documents ordering within event type but not a fabricated total order across all account event types. Retain source stream identity/sequence and do not use venue timestamps as a global order key. |

## Suggested matrix treatment of out-of-scope fields

This inventory deliberately does not erase official fields that do not fit the
initial contract.  For every field in the linked tables, Issue #7 should make
one explicit disposition:

- `Canonical` only if it forms one of the scoped product, order, execution,
  balance, position, margin, or evidence facts with declared type/unit and
  missing handling.
- `AdapterInternal` for decode/reconnect/rate-limit or per-venue control data
  that must not cross the seam.
- `RawEvidence` for audit-only protocol evidence, including unmodelled source
  error codes/text and venue metadata.
- `Unsupported` for requested capabilities such as OCO/TP-SL/trailing/STP or
  option-only values; connect each to a fail-closed capability rejection rule.
- `NotApplicable` only when the official table marks a field unavailable for
  the qualified product/account mode (for example, a linear-only value on
  spot), never merely because the implementation does not yet consume it.

## Source-change caveat

All links above are first-party documentation and were accessed on
2026-08-28.  The tables are the authoritative complete field inventories at
that time; current protocol changes, account entitlement changes, and regional
endpoint availability may differ when a profile is activated.  A profile must
therefore carry both the source reference/access date and live
environment/account qualification evidence, and fail closed if that evidence
is absent or stale.
