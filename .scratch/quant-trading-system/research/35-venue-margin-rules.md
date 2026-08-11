# 首批 Venue 保证金规则与接口矩阵

研究日期：2026-07-29  
范围：OKX、Binance、Gate.io、Bitget；USDT 线性永续；逐仓；单向持仓。  
资料边界：只使用交易所官方 API 文档、帮助中心和合约规则。所有链接访问日期均为 2026-07-29。

## 结论摘要

1. 四家 Venue 都能提供首版所需的杠杆设置、仓位保证金调整、标记价格、预估强平价和强平事实，但风险档位的公开程度不同。
2. Gate.io 的风险档位接口最接近完整 `MarginRules`：直接返回 `initial_rate`、`maintenance_rate`、`leverage_max` 和 `deduction`。Binance 返回 `maintMarginRatio` 与 `cum`，但没有在 API 字段说明中正式定义完整的分段计算和舍入顺序。OKX 返回 `imr/mmr/maxLever` 等档位字段，但逐仓仓位接口的 `imr` 为空，必须结合档位、合约定义和仓位状态。Bitget 返回档位边界、最大杠杆和 MMR，但不返回逐档扣减额。
3. 不能把四家 Venue 归一成一个闭式公式。统一的只能是输入/输出契约：版本化档位、合约乘数、标记价格、费率、保证金余额、Venue 预估强平价和本地确定性求解结果。
4. 只有 Bitget 官方接口明确提供逐仓 `autoMargin` 查询和开关。OKX 的 `Auto transfers` 是资金在交易账户内部的交易模式，不足以证明“亏损仓位自动扫取可用 USDT”；Binance 和 Gate.io 的本次官方资料也没有找到等价的逐仓自动追加开关。后三家必须按 `Unknown/NotExposed` 处理，不能假定已经关闭。
5. 所有数值字段都应按十进制字符串解析成定点整数。API 文档中的 `number/float/double` 类型声明不能成为权威计算类型；具体中间结果、扣减额、强平价和提交参数的舍入仍需 testnet 差分。
6. 风险参数会动态调整，不能编译进代码。每次启动、定时刷新及交易所规则变更后，都应抓取并版本化保存 Venue 返回的原始档位和合约定义。

## 统一能力矩阵

| 能力 | OKX | Binance USDⓈ-M | Gate.io USDT | Bitget USDT-FUTURES |
|---|---|---|---|---|
| 单向模式 | `posMode=net` | `positionSide=BOTH`，dual-side 关闭 | `mode=single` | `posMode=one_way_mode` |
| 逐仓选择 | 下单 `tdMode=isolated` | symbol `marginType=ISOLATED` | 非零 `leverage` / `pos_margin_mode=isolated` | `marginMode=isolated` |
| 读取/设置杠杆 | `leverage-info` / `set-leverage` | `positionRisk` / `leverage` | position / position leverage | position / `set-leverage` |
| 风险档位 | `public/position-tiers` | `leverageBracket` | `risk_limit_tiers` | `query-position-lever` |
| 档位 IMR | `imr` | 最大初始杠杆，可得下限 `1/leverage`，精确订单 IMR 需 Venue 状态验证 | `initial_rate` | 未直接返回；杠杆只给最大值 |
| 档位 MMR | `mmr` | `maintMarginRatio` | `maintenance_rate` | `keepMarginRate` |
| 扣减额 | 未见独立字段 | `cum`，只称辅助快速计算值 | `deduction`，明确为快速计算扣减额 | 未见字段 |
| 仓位 IM/MM | `mmr`；逐仓 `imr` 文档注明为空 | `initialMargin`、`maintMargin` | `initial_margin`、`maintenance_margin` | `marginSize`、`keepMarginRate`、`marginRatio`，无明确 MM 金额 |
| 标记价格 | `markPx` / public mark-price | premium index `markPrice` | contract/position `mark_price` | position `markPrice` |
| 预估强平价 | position `liqPx` | position `liquidationPrice` | position `liq_price` | position `liquidationPrice`；另有估算接口 |
| 手动调整逐仓保证金 | `position/margin-balance` | `positionMargin` | position `margin?change=` | `set-margin` |
| 自动追加查询/开关 | 未证明有等价开关 | 未证明有等价开关 | 未证明有等价开关 | `autoMargin` / `set-auto-margin` |
| 强平/ADL 事实 | 订单 `category`：`full_liquidation`、`partial_liquidation`、`adl` | force orders `autoCloseType`；用户流订单 | `liquidates`、`auto_deleverages`、`is_liq` | order/fill `tradeSide`、`orderSource`；`adl-noti` |
| ADL 风险等级 | position `adl` | `adlQuantile` 0..4 | `adl_ranking` 1..5，6 为无仓/强平中 | `rank` 越接近 1 越靠前 |

## 证据分级与适配器处理

本文对每个字段使用以下证据等级：

- **Confirmed**：当前官方 API 明确定义字段和语义，可以进入规范化事件。
- **Derived**：可由多个官方字段按官方公式推导，但必须保存全部输入和规则版本。
- **ReferenceOnly**：Venue 明确称为估算或参考，只用于对账和风险栅栏，不能覆盖本地权威状态。
- **Unknown**：官方资料没有给出或语义互相不足以闭合；生产不能用默认值填补。
- **TestnetQualified**：在 Confirmed/Derived 基础上，又通过边界差分确定精度、舍入、事件顺序和环境行为。

首版不能把 `Confirmed` 自动提升为 `TestnetQualified`。例如 API 明确返回 MMR，不代表已经证明档位上界属于哪一档，也不代表证明了风险引擎内部的舍入方向。

### 规范字段映射

| 规范字段 | OKX | Binance | Gate.io | Bitget |
|---|---|---|---|---|
| `VenueLeverage` | `lever` | `leverage` | 优先 `lever`，旧 `leverage` 兼容读取 | `leverage` |
| `TierLowerBound` | `minSz` | `notionalFloor` | 前一档 `risk_limit`，首档为 0 | `startUnit` |
| `TierUpperBound` | `maxSz` | `notionalCap` | `risk_limit` | `endUnit` |
| `TierInitialMarginRate` | `imr` | Derived：至少受 `initialLeverage` 限制 | `initial_rate` | Unknown |
| `TierMaintenanceMarginRate` | `mmr` | `maintMarginRatio` | `maintenance_rate` | `keepMarginRate` |
| `TierDeduction` | Unknown | `cum`，语义仅为辅助值 | `deduction` | Unknown |
| `PositionInitialMargin` | isolated 不返回 `imr` | `initialMargin` | `initial_margin` | Unknown |
| `PositionMaintenanceMargin` | `mmr` | `maintMargin` | `maintenance_margin` | Derived/Unknown，API 只给 rate |
| `PositionMarginBalance` | `margin` | `isolatedMargin` / `isolatedWallet`，须差分二者 | `margin` | `marginSize` |
| `VenueLiquidationPrice` | `liqPx` | `liquidationPrice` | `liq_price` | `liquidationPrice` |
| `VenueAdlRank` | `adl` | `adlQuantile.BOTH` | `adl_ranking` | `rank` |
| `AutoMarginState` | Unknown | Unknown | Unknown | `autoMargin` |

映射约束：

- `TierLowerBound/UpperBound` 统一为 USDT 名义价值前，必须先证明 Venue 返回单位；不能只因字段名包含 notional/value 就假定同一单位。
- `TierDeduction` 缺失必须保存 absent，不能本地生成一个数后伪装成 Venue 字段。
- `PositionMarginBalance` 不等于 Portfolio 所有权；它只描述真实 ExchangeAccount 的逐仓桶。
- `VenueLiquidationPrice` 四家均按 `ReferenceOnly` 处理，直到 testnet 只能提升对账可信度，不能变成本地唯一权威值。
- ADL rank 的量纲和方向不统一，规范层保存 Venue 原值与明确的方向枚举，不粗暴缩放成一个共同百分比。

### 动态规则抓取要求

风险档位和交易规则会变化。适配器必须在下列时点重新抓取：

1. 进程启动和恢复准入之前；
2. Venue instrument/risk-rule 变更通知之后；
3. 定时刷新到期时；
4. 杠杆调整被接受之后；
5. 本地 IM/MM/liq-price 与 Venue 超过容差时。

每次抓取必须把以下内容作为一个原子 `MarginRules` 候选保存：

- 原始 HTTP 响应内容哈希；
- Venue、环境、账户身份和认证/公开接口类型；
- 抓取时间与 Venue 响应时间；
- 合约定义版本、完整档位数组和用户级系数；
- 当前杠杆、账户模式、仓位模式和逐仓模式；
- parser/adapter 版本；
- 与上一版本的结构化差异。

规则候选只有在档位连续、边界有序、费率非递减、最大杠杆非递增、合约精度有效，并通过当前持仓的保守重算后，才能通过 `ConfigEvent` 在分片屏障激活。异常响应保留为证据，但不能部分覆盖现行规则。

### 各适配器的最小抓取集合

OKX：

- public instruments；
- public position tiers；
- public mark price；
- account leverage info；
- account positions；
- account config / position mode；
- order/fill history及私有 order channel。

Binance：

- exchangeInfo；
- premiumIndex；
- authenticated leverageBracket；
- account V3；
- positionRisk V3；
- position mode、margin type 和 symbol configuration；
- forceOrders、account update 与 order trade update。

Gate.io：

- futures contracts；
- risk_limit_tiers；
- account/positions；
- single position；
- liquidation history；
- auto_deleverages；
- private order/fill 与 position WebSocket。

Bitget：

- contracts；
- query-position-lever；
- all-position 或 single-position；
- account/margin/position mode；
- ADL rank；
- position/order/ADL notification WebSocket；
- order history 和 fill history。

## OKX

### 可由官方资料确认

- 首版应使用 Futures mode、`net` 持仓模式，并在每笔 SWAP 订单上显式传 `tdMode=isolated`。OKX 没有“给某个持仓全局切逐仓”的接口，保证金模式是订单交易模式的一部分。[API 最佳实践：Cross/Isolated margin mode](https://www.okx.com/docs-v5/trick_en/#trading-account-rest-api)。
- `GET /api/v5/account/leverage-info` 返回 `instId/mgnMode/posSide/lever`；`POST /api/v5/account/set-leverage` 对 SWAP 逐仓 net 模式按合约/合约族设置杠杆。官方还提供 `GET /api/v5/account/adjust-leverage-info`，可返回 `estLiqPx`、`estMgn`、`maxLever`、`minLever` 等估算字段。[OKX Account API](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-leverage)、[设置杠杆](https://www.okx.com/docs-v5/en/#trading-account-rest-api-set-leverage)。
- 公共风险档位由 `GET /api/v5/public/position-tiers` 提供。档位模型需要保存 `tier/minSz/maxSz/imr/mmr/maxLever` 及其适用的 `instType/instFamily/mgnMode`；它与仅用于 Portfolio Margin 限制的 `GET /api/v5/account/position-tiers` 不是同一个契约。[OKX Public Data：Get position tiers](https://www.okx.com/docs-v5/en/#rest-api-public-data-get-position-tiers)。
- U 本位线性永续初始保证金基本关系为 `合约面值 × 合约张数 × 价格 / 杠杆`；初始保证金率为 `1 / leverage`。逐仓维持保证金率为 `(保证金余额 + 逐仓 UPL) / (维持保证金 + 强平费用)`，USDT 本位持仓价值使用标记价格。[Futures margin calculation rules](https://www.okx.com/en-us/help/futures-margin-calculation-rules)。
- `GET /api/v5/account/positions` 对逐仓持仓返回 `margin`、`mgnRatio`、`mmr`、`liqPx`、`markPx`、`lever`、`upl`、`notionalUsd`；官方明确 `liqPx` 是按当前权益和保证金率估算的标记价格，资金费、仓位变化和快速行情都会改变它；`imr` 字段仅适用于 cross，逐仓为空。[OKX positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions)。
- `POST /api/v5/account/position/margin-balance` 对逐仓仓位执行 `add` 或 `reduce`，请求含 `instId/posSide/type/amt`。[OKX increase/decrease margin](https://www.okx.com/docs-v5/en/#trading-account-rest-api-increase-decrease-margin)。
- `GET /api/v5/public/mark-price` 返回 `instType/instId/markPx/ts`。UPL 的权威展示值也按 `markPx` 计算，last-price 版本只作展示。[OKX mark price](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-mark-price)。
- 强平/ADL 可从订单/成交信息的 `category` 区分：`full_liquidation`、`partial_liquidation`、`adl`；订单还返回 `ordId/instId/side/posSide/fillSz/fillPx/fee/pnl` 等经济事实。[OKX orders channel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-order-channel)、[订单历史](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-history-last-7-days)。
- 逐仓达到 MMR 100% 或以下会进入撤单、部分减仓或全部强平；较大仓位按档位逐级降低。维持保证金和强平费用都参与触发条件。[Tiered maintenance margin ratio rules](https://www.okx.com/en-gb/help/v-tiered-maintenance-margin-ratio-rules)、[Liquidation FAQ](https://www.okx.com/en-gb/help/liquidation-faq)。
- 合约精度和乘数从 `GET /api/v5/public/instruments` 的 `ctVal/ctMult/ctValCcy/tickSz/lotSz/minSz` 获取；所有字段是十进制字符串。[OKX instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)。

### 文档边界与矛盾

- `public/position-tiers` 给出档位费率，但 API 文档没有为逐仓 USDT SWAP 给出可独立复刻所有中间值的扣减额字段或完整舍入次序。
- 帮助中心的公式说明了整体关系，`positions.liqPx` 又明确只是估算值；因此本地阈值必须与 Venue `liqPx` 并列保存，不能宣称完全等价。
- OKX 已在 2024 年停止 Futures isolated 的 Manual transfers，切到 `Auto transfers`。[变更公告](https://www.okx.com/help/okx-will-stop-supporting-quick-margin-and-manual-transfers-modes-in-isolated)。这里的 Auto transfers 描述的是交易账户内部资金自动划转模式，官方资料没有证明它等价于“亏损时自动从可用 USDT 补充逐仓仓位”。不能将其映射成 `autoMargin=on`，也不能据此声称自动追加已经关闭。

### 必须 testnet 差分

- 在档位下界、上界、恰好跨档一 tick 的 IM/MM、最大可开张数和 `liqPx`。
- 减少逐仓保证金时的最小单位、拒绝边界和 Venue 向哪个方向舍入。
- `set-leverage` 在已有仓位、挂单及跨档情况下是否立即改变 `margin/mgnRatio/liqPx`。
- 资金费结算、手续费和挂单强平费用如何进入逐仓 `margin/mmr/liqPx`。
- Futures mode + net + isolated 下是否存在账户/UI 隐藏的自动补保证金设置及可查询证据；找不到则生产准入为 `Unknown`。
- 部分强平的订单/成交推送顺序、`category`、费用、负 `tradeId` 等字段是否在 demo 环境与生产一致。

## Binance USDⓈ-M Futures

### 可由官方资料确认

- 单向模式由 position mode 的 dual-side 关闭表达，仓位侧为 `BOTH`；逐仓通过 `POST /fapi/v1/marginType` 设置 `ISOLATED`，杠杆通过 `POST /fapi/v1/leverage` 设置。[Binance USDⓈ-M Trade API](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade)。
- `GET /fapi/v1/leverageBracket` 是用户级签名接口。每档返回 `bracket/initialLeverage/notionalFloor/notionalCap/maintMarginRatio/cum`，可选 `notionalCoef` 表示用户档位被调整后的乘数。`cum` 的官方定义只到“用于快速计算的辅助数字”。[Notional and Leverage Brackets](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/account#notional-and-leverage-brackets)。
- `GET /fapi/v3/account` 返回逐 symbol 的 `isolatedMargin/notional/isolatedWallet/initialMargin/maintMargin`；`GET /fapi/v3/positionRisk` 返回 `entryPrice/breakEvenPrice/markPrice/unRealizedProfit/liquidationPrice/leverage/maxNotionalValue/marginType/isolatedMargin/positionSide/updateTime`。[Account Information V3](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/account#account-information-v3-user_data)、[Position Information V3](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#position-information-v3)。
- `POST /fapi/v1/positionMargin` 只用于 isolated symbol，`type=1` 增加、`type=2` 减少；单向模式 `positionSide` 默认为 `BOTH`。历史接口 `GET /fapi/v1/positionMargin/history` 返回 `deltaType/amount/asset/time/positionSide`。[Modify Isolated Position Margin](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#modify-isolated-position-margin)。
- `GET /fapi/v1/premiumIndex` 返回 `markPrice/indexPrice/lastFundingRate/nextFundingTime/time`。[Mark Price](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/market-data#mark-price)。
- `GET /fapi/v1/adlQuantile` 返回 0..4，风险由低到高，约每 30 秒更新；单向模式使用 `BOTH`。[Position ADL Quantile Estimation](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#position-adl-quantile-estimation)。
- `GET /fapi/v1/forceOrders` 用 `autoCloseType=LIQUIDATION|ADL` 区分强平与 ADL，返回 `orderId/clientOrderId/status/price/avgPrice/origQty/executedQty/cumQuote/timeInForce/type/side/time/updateTime` 等；`clientOrderId` 示例具有 `autoclose-` 前缀。[User's Force Orders](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade#users-force-orders)。
- 数量和价格提交精度从 `GET /fapi/v1/exchangeInfo` 的 `PRICE_FILTER.tickSize`、`LOT_SIZE.stepSize`、`MARKET_LOT_SIZE.stepSize`、最小/最大值获取；不能只使用 `pricePrecision` 或 `quantityPrecision`。[Exchange Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/market-data#exchange-information)。

### 文档边界与矛盾

- API 给出了 `cum`，但当前字段说明没有正式定义“维持保证金 = notional × MMR − cum”的完整适用范围、边界归属和舍入次序。该常见解释只能作为待验证假设，不能直接成为权威规则。
- `initialLeverage` 是该档最大初始杠杆，不是当前用户所选杠杆，也不是足以覆盖开仓订单、费用缓冲和所有风控校验的独立 IMR 公式。
- 官方 Futures API 本次没有找到等价于 Bitget `autoMargin` 的逐仓自动追加查询/开关。仅存在手动 `positionMargin`；不能从“未找到字段”推导功能必然关闭。
- `positionRisk.liquidationPrice` 是 Venue 输出，但当前 API 参考没有公开其完整公式及舍入方式。

### 必须 testnet 差分

- `notionalFloor/notionalCap` 边界包含关系，`notionalCoef` 对上下界和 `cum` 的实际变换。
- 由 bracket 推导的 MM 与 `account.maintMargin` 在每个边界、手续费、挂单和资金费之后是否一致。
- `initialMargin` 如何合并持仓 IM、挂单 IM、reduce-only 单与费用缓冲。
- `positionMargin` 最小步长、减保证金拒绝边界和响应 `amount` 的精度；API schema 把 amount 标成 float，客户端仍必须发送/解析十进制文本。
- 强平/ADL 在用户数据流、forceOrders 和成交历史中的先后、去重身份与费用字段。
- 是否存在 UI 或账户配置级 Futures 自动补保证金；若没有可读 API 证据，生产准入保持 `Unknown` 并拒绝新增风险。

## Gate.io USDT Perpetual

### 可由官方资料确认

- `GET /api/v4/futures/usdt/risk_limit_tiers` 返回逐合约完整档位：`tier/risk_limit/initial_rate/maintenance_rate/leverage_max/deduction`；`deduction` 明确定义为维持保证金快速计算扣减额。[Gate API：risk limit tiers](https://www.gate.com/docs/developers/apiv4/en/#futures-query-risk-limit-tiers)。
- Gate 说明风险限额由所选杠杆决定，杠杆越低允许的风险限额越大；有效仓位价值包含持仓和挂单，并以标记价格和合约乘数计值。[风险限额说明](https://www.gate.com/help/futures/futures-logic/22162)。
- position 返回 `size/leverage/risk_limit/leverage_max/maintenance_rate/value/margin/entry_price/liq_price/mark_price/initial_margin/maintenance_margin/unrealised_pnl/adl_ranking/risk_limit_table/average_maintenance_rate/pos_margin_mode/lever/update_id`。官方特别说明，分档后的实际维持保证金率应看 `average_maintenance_rate`，`liq_price` 仅供参考，实际触发按 position MMR 或账户维持保证金水平。[Gate API：positions](https://www.gate.com/docs/developers/apiv4/en/#futures-list-all-positions-of-a-user)。
- 单向模式为 `mode=single`。更新 position leverage 时 `leverage != 0` 表示 isolated，`leverage=0` 表示 cross；新字段 `pos_margin_mode` 和 `lever` 正逐步替代旧字段。[Gate API：update position leverage](https://www.gate.com/docs/developers/apiv4/en/#futures-update-position-leverage)。
- `POST /api/v4/futures/{settle}/positions/{contract}/margin?change=` 调整逐仓保证金，正数增加、负数减少。[Gate API：update position margin](https://www.gate.com/docs/developers/apiv4/en/#futures-update-position-margin)。
- contract 返回 `quanto_multiplier/order_price_round/mark_price_round/order_size_min/enable_decimal/leverage_min/leverage_max/mark_price` 等稳定规则；数量是否允许小数由 `enable_decimal` 决定。[Gate API：futures contracts](https://www.gate.com/docs/developers/apiv4/en/#futures-list-all-futures-contracts)。
- Gate 使用标记价格判断强平，而非最新成交价；逐仓保证金余额低于维持保证金时触发，资金费也会降低逐仓保证金并触发强平。[Perpetual Contract FAQs](https://www.gate.com/help/futures/futures/16695/perpetual-contract-faqs/perpetual-contract-faqs)。
- 私有 `GET /api/v4/futures/usdt/liquidates` 返回用户强平历史；`GET /api/v4/futures/usdt/auto_deleverages` 返回 ADL 订单信息；position 的 `adl_ranking` 为 1..5，1 最高，6 表示无仓或强平中；订单还提供 `is_liq` 和内部 source text。[Gate API：liquidates](https://www.gate.com/docs/developers/apiv4/en/#futures-query-liquidation-history)、[ADL orders](https://www.gate.com/docs/developers/apiv4/en/#futures-query-adl-auto-deleveraging-order-information)。
- 公共 `liq_orders` 只有 `time/contract/size/order_size/order_price/fill_price/left`；私有查询才增加 `entry_price/liq_price/mark_price/order_id`，因此不能用公共 feed 代替账户强平事实。[Gate API：liquidation order history](https://www.gate.com/docs/developers/apiv4/en/#futures-query-liquidation-order-history)。

### 文档边界与矛盾

- API 同时保留 `maintenance_rate`、`average_maintenance_rate` 和 `deduction`。字段说明支持梯度计算，但没有在 API 参考中冻结所有边界和舍入顺序。
- `liq_price` 明确仅供参考；强平 FAQ 中的示例包含手续费，但并未为当前所有 USDT 合约和新版风险表提供一个可直接通用的定点公式。
- 本次官方 API/帮助中心没有找到逐仓“自动追加保证金”状态或开关。不能把 cross margin 行为、自动减仓或 risk-limit 自动调整误认为自动补保证金。
- API 在某些 schema 中仍使用 `number(double)`，而多数经济字段返回 string；适配器必须统一按收到的原始十进制文本编码，不能用 double 中转。

### 必须 testnet 差分

- `risk_limit` 档位边界和 `deduction` 是否满足本地梯度 MM 计算，特别是档位切换前后一最小价格/数量单位。
- `maintenance_rate` 与 `average_maintenance_rate` 在单档、多档和减仓后的关系。
- `leverage`/`lever`、`pos_margin_mode` 新旧字段在真实 API 与 testnet 的共存及优先级。
- `change` 的最小单位、负数移除边界、保证金和 `liq_price` 的舍入方向。
- `liquidates`、普通 order/fill、`auto_deleverages` 的去重键、时间范围和事件顺序。
- 是否存在无法从 API 读取的逐仓自动补保证金设置；无证据时生产准入为 `Unknown`。

## Bitget USDT-FUTURES

### 可由官方资料确认

- `GET /api/v2/mix/market/query-position-lever` 返回 `level/startUnit/endUnit/leverage/keepMarginRate`。MMR 低于档位维持保证金率会触发部分或全部强平。[Get Position Tier](https://www.bitget.com/api-doc/contract/position/Get-Query-Position-Lever)。
- 合约定义由 `GET /api/v2/mix/market/contracts` 返回：`pricePlace/priceEndStep/volumePlace/sizeMultiplier/minTradeNum/minTradeUSDT/minLever/maxLever/openCostUpRatio/makerFeeRate/takerFeeRate` 等。[Get Contract Config](https://www.bitget.com/api-doc/contract/market/Get-All-Symbols-Contracts)。
- `GET /api/v2/mix/position/all-position` 或 single-position 返回 `marginSize/leverage/openPriceAvg/marginMode/posMode/unrealizedPL/liquidationPrice/keepMarginRate/markPrice/marginRatio/autoMargin/deductedFee/totalFee`。`liquidationPrice <= 0` 表示低风险、当前没有强平价。[Get All Positions](https://www.bitget.com/api-doc/classic/contract/position/get-all-position)。
- 单向逐仓杠杆使用 `POST /api/v2/mix/account/set-leverage` 的 `leverage`；`POST /api/v2/mix/account/set-margin-mode` 设置 `isolated`。[Change Leverage](https://www.bitget.com/api-doc/classic/contract/account/Change-Leverage)、[Set Margin Mode](https://www.bitget.com/api-doc/classic/contract/account/Change-Margin-Mode)。
- `POST /api/v2/mix/account/set-margin` 只适用于逐仓，amount 正数增加、负数减少。[Adjust Position Margin](https://www.bitget.com/api-doc/classic/contract/account/Change-Margin)。
- `POST /api/v2/mix/account/set-auto-margin` 明确设置逐仓 `autoMargin=on|off`；position 返回同名状态。这是四家中唯一由本次官方 API 资料直接证明可读且可写的自动追加保证金契约。[Set Isolated Position Auto Margin](https://www.bitget.com/api-doc/classic/contract/account/Set-Auto-Margin)。
- 官方给出了逐仓预估强平价公式：`[position margin + pre-calculated offset − position size × avg entry × direction] / [position size × (MMR + taker fee ratio − direction)]`，其中 long direction=1、short=-1；预估值仍会随市场、交易和保证金变化。[Estimated Liquidation Price](https://www.bitget.com/support/articles/12560603808759)。
- `GET /api/v2/mix/position/adlRank` 的现行 `rank` 越接近 1 越容易 ADL；`adlRank` 已标记 deprecated。[Get Position ADL Rank](https://www.bitget.com/api-doc/classic/contract/position/Get-Position-Adl)。
- 私有 `adl-noti` WebSocket 推送 `symbol/side/status=triggered/price/amount/ts`；order/fill channel 通过 `enterPointSource=SYS`、`tradeSide` 的 `reduce_*`、`burst_*`、`dte_sys_adl_*` 区分部分强平、完全强平和 ADL。[ADL Notification Channel](https://www.bitget.com/api-doc/classic/contract/websocket/private/ADL-Notification-Channel)、[Order Channel](https://www.bitget.com/api-doc/contract/websocket/private/Order-Channel)。

### 文档边界与矛盾

- v2 档位接口没有返回扣减额，但强平公式引用 `pre-calculated offset`；官方 API 没有在同一契约中提供该值。因此不能只靠 v2 档位响应完整复刻 `liquidationPrice`。
- `keepMarginRate` 被描述为档位 MMR，而 position 的 `marginRatio` 又被描述为维护保证金率；两者语义不同但命名接近，适配器必须分别建模。
- ADL 接口经历过字段语义变更：旧 `adlRank` 与新 `rank` 方向可能相反。只使用现行 `rank`，并把 schema/变更日期纳入适配器版本。
- `adl-noti.amount` 文档称单位是 quote coin，而普通 position size 是 base coin；必须通过实际样本确认，不得直接与 position quantity 相减。
- Bitget 同时维护 Classic v2 与 UTA v3。首版必须锁定实际账户类型和接口族，禁止混用相似字段。本文矩阵以 Classic v2 为主；UTA 只作为未来独立 capability。

### 必须 testnet 差分

- `startUnit/endUnit` 边界包含关系、缺失的 pre-calculated offset 以及 `liquidationPrice` 的精确复现。
- `pricePlace + priceEndStep` 与实际 tick、`volumePlace + sizeMultiplier` 与实际 quantity step 的组合规则。
- `autoMargin=off` 启动校验；开关后的 position/WS 生效延迟，以及资金不足时是否产生独立账务/仓位事件。
- `set-margin` 负值边界、最小精度和对 `marginSize/liquidationPrice` 的舍入。
- `rank`、`adl-noti`、order/fill 中 `dte_sys_adl_*` 的事件顺序、amount 单位和去重身份。
- partial liquidation 的 `reduce_*` 与 full liquidation 的 `burst_*` 在 one-way mode 下的准确 side/quantity 语义。

## 精度与舍入结论

### 已能确定

- 四家均通过字符串或离散过滤器提供价格、数量、档位和金额信息，适配器应先按原始十进制文本解析，再转换为系统定点整数。
- 订单合法化必须使用 Venue 的交易规则：
  - OKX：`tickSz/lotSz/minSz/ctVal/ctMult`；
  - Binance：`PRICE_FILTER.tickSize`、`LOT_SIZE/MARKET_LOT_SIZE.stepSize`；
  - Gate.io：`order_price_round/mark_price_round/order_size_min/quanto_multiplier/enable_decimal`；
  - Bitget：`pricePlace/priceEndStep/volumePlace/sizeMultiplier/minTradeNum`。
- Venue 报告的 `liqPx/liquidationPrice` 是参考或估算值，不是本地计算覆盖 Venue 的理由。应同时保存本地结果和 Venue 结果，超过按 tick 定义的容差即产生对账异常。

### 仍不能由官方文档证明

- 四家对 IM、MM、扣减额、强平费用和强平价每个中间步骤的精确舍入方向。
- 订单名义价值落在档位上下界时使用前档还是后档的全部细节。
- Binance `cum`、Bitget `pre-calculated offset`、OKX 未暴露扣减额之间是否能按同一数学形式解释。
- 标记价格自身展示精度与风险引擎内部精度是否完全相同。

因此首版本地规则必须采取保守舍入：增加保证金要求的方向取整；但这只是内部风控政策，不能标记为 Venue 官方公式。精确对账容差应由每 Venue、Instrument、规则版本的 testnet 证据决定。

## Testnet 差分测试计划

每家至少选 BTCUSDT 和一个低流动性 USDT 永续，覆盖以下矩阵：

1. **账户准入**
   - 单向模式、逐仓、单资产 USDT；
   - 当前杠杆；
   - 自动追加保证金必须明确为 `off`；没有 API 证据的 Venue 必须保持 `Unknown`，不能上线新增风险。
2. **档位边界**
   - 每档下界减一最小单位、下界、上界减一最小单位、上界；
   - 空仓、已有仓位、有同向挂单、反向 reduce-only 挂单；
   - 对比 Venue IM/MM、风险档位、最大杠杆和本地结果。
3. **逐仓调整**
   - 增加最小单位、减少最小单位、减少到刚好可接受、再减一单位被拒绝；
   - 记录响应、仓位快照、私有 WS、账务流水和强平价变化。
4. **杠杆调整**
   - 无仓、持仓中、存在挂单、跨风险档位；
   - 验证是否隐式搬动保证金、是否取消订单、是否改变强平价及其事件顺序。
5. **费用和资金费**
   - maker rebate、taker fee、资金费支付/收取前后；
   - 验证逐仓 equity、MM、强平价和可移除保证金。
6. **强平和 ADL**
   - testnet 能触发则捕获完整 REST/WS/订单/成交/账务序列；
   - 不能安全触发时至少保存 Venue 官方样例和适配器离线 golden payload，不用猜测生产字段。
7. **舍入**
   - 构造半 tick、半 step、高精度金额和档位边界；
   - 比较请求拒绝、Venue 规范化结果及本地保守舍入。

每个样本应归档：

- 原始请求与响应（去除凭证/签名）；
- 原始私有 WS；
- 合约定义和完整风险档位快照；
- Venue 时间、接收时间和测试 RunIdentity；
- 账户模式、仓位模式、杠杆、auto-margin 状态；
- 预期定点计算、Venue 字段、差值和结论。

## 对首版 `MarginRules` 的最小落地要求

每个 `Venue + Instrument + AccountMode` 的版本化规则至少包含：

- 合约乘数、价格 tick、数量 step、金额 scale；
- 档位有序区间及边界语义；
- 最大杠杆、IMR、MMR；
- Venue 提供的 `cum/deduction`，没有则显式 absent；
- 标记价格来源和最大陈旧时间；
- taker liquidation fee / 普通 taker fee 的适用方式；
- 自动追加保证金 capability：`SupportedOn/SupportedOff/NotExposed/Unknown`；
- 手动 margin adjustment 的最小单位和拒绝边界；
- Venue 报告的 IM/MM/liq-price 字段映射；
- 强平、部分强平和 ADL 的事件分类与去重身份；
- testnet 证据版本和允许的 tick/金额对账容差。

未由官方接口或 testnet 证明的字段必须保持 `Unknown`，不得以零、默认 false 或其他 Venue 的公式填充。
