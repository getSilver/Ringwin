# 首批交易所适配器能力合同

研究日期：2026-07-25

## 结论

OKX、Binance、Gate.io 和 Bitget 均有官方 API 覆盖普通现货和 USDT 线性永续，并能表达首版要求的单向持仓、逐仓保证金及基础订单类型。四家可以继续作为首批候选，但生产下单仍须通过本文末尾的测试环境准入项；官方文档没有确认的行为均不得成为实现假设。

统一适配器不能把各 Venue 压成一个“功能相同”的接口：

- 客户端订单号只用于关联和对账；四家官方资料均未提供可依赖的历史级 exactly-once 保证。发送结果不明时进入 `Unknown`，先查询和对账，禁止盲目重发。
- 私有 WebSocket 是低延迟通知源，不是可恢复事实日志。官方资料没有为四家提供覆盖订单、成交、余额和仓位的全局连续序号及重放游标；断线后必须使用 REST 重建。
- `amend` 必须区分原地修改、撤单重报和部分成功的 cancel-replace，不能用一个布尔能力表示。
- 现货没有 Venue 原生 `reduce-only`；只在本地投资组合及账户风控中限制卖出数量。永续的 `reduce-only` 才映射到 Venue 参数。
- 限流按 Venue、产品、账户、Instrument 和操作分别建模，并读取官方响应或元数据；不能把研究时的数值写死为全局常量。

## 1. 产品与基础订单准入

| 能力 | OKX | Binance | Gate.io | Bitget |
|---|---|---|---|---|
| 普通现货 | `SPOT`, `tdMode=cash` | Spot | Spot | Classic Spot v2 |
| USDT 线性永续 | `SWAP` | USDⓈ-M perpetual | Futures `settle=usdt` | Classic Mix `USDT-FUTURES` |
| 单向持仓 | `net` | `dualSidePosition=false` | `single` / dual mode 关闭 | `one-way-mode` |
| 逐仓 | SWAP `tdMode=isolated` | symbol margin type `ISOLATED` | 非零 leverage 表示逐仓 | `marginMode=isolated` |
| Limit / Market | 是 / 是 | 是 / 是 | 是 / 是 | 是 / 是 |
| GTC / IOC / FOK | 是 / 是 / 是 | 是 / 是 / 是 | 现货：是；永续 FOK：**unknown** | 是 / 是 / 是 |
| Post-only | `post_only` | Spot `LIMIT_MAKER`；USDⓈ-M `GTX` | `poc` | `post_only` |
| Reduce-only | 仅 FUTURES/SWAP net mode | 仅 USDⓈ-M one-way；普通现货不适用 | 永续支持；普通现货不适用 | 仅永续 one-way；普通现货不适用 |

来源：

- OKX 的 `SPOT`/`SWAP`、交易模式、持仓模式、`ordType` 和 `reduceOnly` 定义见 [OKX API v5](https://www.okx.com/docs-v5/en/)。
- Binance 现货订单类型见 [Spot Trade API](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/trade)，USDⓈ-M 的 `GTX`、`reduceOnly`、持仓和保证金模式见 [USDⓈ-M Trade API](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade)。
- Gate.io 现货/USDT 永续、订单、持仓和保证金字段见 [API v4](https://www.gate.com/docs/developers/apiv4/en/)；官方页面当前未清晰确认 USDT 永续普通订单的 FOK，故保留为 unknown。
- Bitget 现货订单范围见 [Spot Place Order](https://www.bitget.com/api-doc/spot/trade/Place-Order)，USDT 永续、one-way、逐仓、TIF 与 reduce-only 见 [Contract Batch Order](https://www.bitget.com/api-doc/classic/contract/trade/Batch-Order)。

适配器按产品声明 `native_reduce_only`。首版不得把普通现货的本地风险限制伪装成交易所原生 reduce-only。

## 2. 能力矩阵

| 能力 | OKX | Binance Spot / USDⓈ-M | Gate.io Spot / USDT Futures | Bitget Classic Spot / USDT Futures |
|---|---|---|---|---|
| L2 建簿 | WS snapshot + delta | REST snapshot + WS diff depth | REST `with_id` snapshot + WS delta | WS 首包 snapshot，随后 delta |
| 缺口检测 | `seqId/prevSeqId`；JSON checksum 自 2026-06 起废弃 | Spot `U/u`；Futures 另校验 `pu` | `U/u`，按官方 snapshot 衔接流程 | `seq/pseq` 和 checksum；维护/重启可重置序号 |
| 公共 WS 连续性 | 仅 L2 通道有明确链式序号 | L2 有明确 update ID | L2 有明确 update ID | L2 有明确 `seq/pseq` |
| 私有 WS 全局序号/游标 | **unknown** | **unknown** | **unknown** | **unknown** |
| 私有 WS 初始订单快照 | 无 | 不应依赖；REST bootstrap | 不应依赖；REST bootstrap | Spot 明确无；Futures 不应依赖 |
| 客户端订单号范围 | 仅活跃/部分成交订单要求 User ID 内唯一；终态后可复用 | 仅 open orders 范围唯一 | `text`/`t-...` 可关联；唯一范围与保留期 **unknown** | 支持 `clientOid`，重复有错误码；唯一范围与保留期 **unknown** |
| 客户端订单号严格幂等 | 否 | 否 | **unknown**，不得假定 | **unknown**，不得假定 |
| 下单/撤单 | REST + 私有 WS | REST/WS API；产品接口分离 | REST + WS trade API | REST；部分 WS trade 需权限且共享配额 |
| 单笔改单 | 原地 amend，失败可选 `cxlOnFail` | Spot keep-priority amend 或 cancel-replace；Futures modify | Spot PATCH；Futures amend | Futures 修改价格/数量明确为异步撤旧建新 |
| 原子 cancel-replace | 未确认 | Spot 明确存在 cancel 成功/new order 失败等部分结果；Futures未确认 | **unknown** | Spot batch cancel-replace 非原子；Futures modify 非原地 |
| 批量 API | place/cancel/amend，最多 20，逐订单结果 | Spot 有 batch/cancel；Futures place/modify/cancel multiple | Spot/Futures place/cancel/amend | Spot/Futures place/cancel；Spot cancel-replace |
| 限流来源 | REST/WS 交易配额共享，操作桶及 instrument/subaccount 规则 | `exchangeInfo`、响应 headers、order counters | 官方限流表及响应 headers；存在 fill-ratio 动态限制 | 每 endpoint 的 UID/IP 限额；WS trade 与 REST 共享 |
| REST 对账 | pending/history/order/fills/balance/positions | open/all/query orders、trades、account/balance/positions/income | open/finished/order/trades/balance/positions/account book | order detail/pending/history/fills/account/positions |
| 传输超时结果 | 未保证未受理，必须 Unknown | Spot `-1007` 明确 send/execution unknown；Futures 部分 503 明确 unknown | 官方未确认，必须 Unknown | timeout 错误存在，但受理结果语义 **unknown** |
| 非生产环境 | Demo REST + public/private WS | Spot Testnet；USDⓈ-M testnet 存在但生产等价性 **unknown** | Spot/Futures REST/WS TestNet | Demo API key + PAP WS；REST 行为须逐接口验证 |
| 断线恢复 | 重订阅、重建 L2、REST 全量对账 | 重建 L2、重建 user stream、REST 对账 | 重建 L2、重订阅私有流、REST 对账 | 重建 L2、重订阅私有流、REST 对账 |

## 3. Venue 细节

### 3.1 OKX

#### 行情与私有流

`books` 类通道以 snapshot 建簿，随后应用 update；连续性由 `seqId/prevSeqId` 检查。OKX 已在 2026-06 停用 JSON order-book checksum，字段会保留但恒为 0，不能再用于完整性判断；应只使用序号并在断链时重订阅重建。[OKX checksum deprecation](https://www.okx.com/en-us/help/okx-order-book-channels-checksum-field-deprecation)

`orders` 私有通道订阅时不推送初始订单快照。官方没有定义覆盖 orders、fills、account 和 positions 的统一连续序号或断线重放游标；启动和重连必须先 REST 查询挂单、订单历史/明细、成交、余额与仓位。[OKX API v5](https://www.okx.com/docs-v5/en/)

#### 订单与身份

`clOrdId` 只要求在 User ID 下的活跃及部分成交订单间唯一，终态后可复用，因此不是历史级幂等键。适配器仍应生成永不复用的内部 ID；无权威回报时按 `clOrdId` 查询，确认不存在前不得重发。[OKX API v5](https://www.okx.com/docs-v5/en/)

REST 和私有 WS 均支持 place/cancel/amend 及批量版本；批量最多 20 个并返回逐项结果。Amend 支持 `cxlOnFail`，但提交响应不代替 orders channel 或 get-order 的最终事实。官方未提供可依赖的原子 cancel-replace。[OKX API v5](https://www.okx.com/docs-v5/en/)

交易类 REST 与 WS 共享限额，place/amend/cancel 使用不同桶，并叠加 instrument、subaccount 及 fill-ratio 规则；例如子账户的新单与改单还有聚合上限。实现必须按响应与账户等级配置，不能只使用单个固定 QPS。[OKX API v5](https://www.okx.com/docs-v5/en/)

Demo 通过 `x-simulated-trading: 1` 使用独立 REST/public/private WS；非交易功能并非全部可用。[OKX API v5](https://www.okx.com/docs-v5/en/)

### 3.2 Binance

#### 行情与私有流

Spot 先缓存 diff-depth，再取得 REST snapshot，以 `lastUpdateId` 与首个 `[U,u]` 桥接；随后若 `U > local_update_id + 1` 必须丢弃本地簿并重建。[Spot WebSocket Streams](https://developers.binance.com/en/docs/products/spot/testnet/web-socket-streams)

USDⓈ-M 同样以 REST snapshot 加 WS delta 建簿，并要求后续事件的 `pu` 等于前一事件的 `u`；不相等即重建。[USDⓈ-M local order book](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/websocket-market-streams/How-to-manage-a-local-order-book-correctly)

Spot User Data Stream 的 `executionReport` 和 USDⓈ-M 的 `ORDER_TRADE_UPDATE` 提供低延迟事实通知，但官方没有定义跨私有事件的全局连续序号或重放游标。[Spot User Data Stream](https://developers.binance.com/en/docs/products/spot/user-data-stream)、[USDⓈ-M Order Update](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/user-data-streams/Event-Order-Update) 重连后必须重新订阅，并 REST 查询 open/all orders、trades、account、balance 和 positions。

#### 订单与身份

Spot 和 USDⓈ-M 的 `newClientOrderId` 只保证在 open orders 范围唯一；它不是历史级幂等键。Spot 支持 query/cancel by original client ID，Futures 也支持按 client ID 查询和撤销。[Spot Trade API](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/trade)、[USDⓈ-M Trade API](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade)

Spot cancel-replace 的官方结果矩阵允许 cancel 成功而新单失败等部分结果，因此必须输出两个独立结果。USDⓈ-M modify 也不能抽象成可移植的原子替换。[Spot Trade API](https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/trade)

Spot 明确规定匹配引擎 10 秒无响应时返回 `-1007`，发送和执行状态均 unknown，并要求先观察 User Data Stream，再查询订单状态。[Spot REST general information](https://developers.binance.com/en/docs/products/spot/rest-api) USDⓈ-M general info 也区分确定失败与 execution unknown 的 503；适配器统一进入 `Unknown` 后查询。[USDⓈ-M general info](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/general-info)

Spot 通过 `exchangeInfo` 暴露 RAW_REQUESTS、REQUEST_WEIGHT 和 ORDERS 限制，并用 headers 返回 IP weight 与 account order count；429 必须退避，反复违反会导致 418 ban。[Spot REST general information](https://developers.binance.com/en/docs/products/spot/rest-api) USDⓈ-M 同样按 IP weight 与 order count 管理，具体值不得跨产品复用。[USDⓈ-M general info](https://developers.binance.com/en/docs/products/derivatives-trading-usds-futures/general-info)

Spot Testnet 有独立 REST/WS 且会重置数据。[Spot Testnet](https://developers.binance.com/en/docs/products/spot/testnet/rest-api) USDⓈ-M testnet 可用于接口验证，但本次官方资料未确认与生产功能完全等价，故生产等价性标为 unknown。

### 3.3 Gate.io

#### 行情与私有流

Spot 与 Futures 的 order-book update 提供 `U/u`；Futures 官方给出缓存 delta、取得 `with_id=true` REST snapshot、桥接并在缺口时重建的完整流程。[Spot WebSocket](https://www.gate.com/docs/developers/apiv4/ws/en/)、[Futures WebSocket](https://www.gate.com/docs/developers/futures/ws/en/) Spot 与 Futures 还提供官方 SBE 行情，但 SBE schema 必须独立版本化，不能和 JSON codec 共用布局。

私有 WS 覆盖 orders、user trades、balances，Futures 另有 positions；页面提供时间和部分实体 update ID，但未定义跨通道的全局连续序号或 resume token。因此重连必须 REST 对账，而不是从最后一个 WS 消息继续。[Gate API v4](https://www.gate.com/docs/developers/apiv4/en/)

#### 订单与身份

Spot/Futures 的 `text`（自定义值使用 `t-` 前缀）可用于关联、查询和撤销，但官方未确认唯一范围、保留期或重复提交幂等行为。任何 timeout 都必须进入 `Unknown`，按 order ID/custom ID 查询后才能决定下一步。[Gate API v4](https://www.gate.com/docs/developers/apiv4/en/)

REST 和 WS trade API 提供 place/cancel/amend；Spot 与 Futures 均有批量操作。官方未确认 cancel-replace 的原子性，适配器不得声明该能力。[Spot WebSocket](https://www.gate.com/docs/developers/apiv4/ws/en/)、[Futures WebSocket](https://www.gate.com/docs/developers/futures/ws/en/)

官方限流按市场、endpoint、UID/API key/IP 等维度划分，响应包含 limit/remain/reset，并叠加 fill-ratio 动态限制；批量操作不能简单算作一次请求。[Gate API v4](https://www.gate.com/docs/developers/apiv4/en/)

官方文档提供 Spot/Futures REST/WS TestNet。生产准入仍须实测 REST 历史分页完整性、Futures FOK、custom ID 重复与 timeout 后的查询行为。[Gate API v4](https://www.gate.com/docs/developers/apiv4/en/)

### 3.4 Bitget

首版固定使用 Classic Spot v2 + Classic Mix v2；不得把 UTA v3 的字段、L2 序号或账户语义混入同一 codec。

#### 行情与私有流

Classic `books` 首包为 snapshot，随后为 update；`seq/pseq` 可识别乱序和丢包，checksum 校验前 25 档。发生不连续或 checksum 失败时必须重新订阅重建；symbol maintenance 期间序号可能重置。[Contract Order Book Channel](https://www.bitget.com/api-doc/contract/websocket/public/Order-Book-Channel) UTA 已提供更明确的 `seq/pseq` 重置和衔接规则，但这不能反推 Classic 的未写明行为。[UTA Order Book Channel](https://www.bitget.com/api-doc/uta/websocket/public/Order-Book-Channel)

Spot/Futures 私有 orders/fills/account/positions 通道没有官方定义的全局连续序号和 replay cursor；Spot order channel 明确订阅时无初始快照。[Spot Order Channel](https://www.bitget.com/api-doc/spot/websocket/private/Order-Channel)、[Contract Order Channel](https://www.bitget.com/api-doc/contract/websocket/private/Order-Channel) 重连后必须 REST 对账。

#### 订单与身份

`clientOid` 可用于订单查询和撤销，重复值有明确错误码，但官方没有说明唯一范围、保留期或“重复请求返回原结果”的幂等承诺。[WebSocket error codes](https://www.bitget.com/api-doc/classic/spot/error-code/websocket)、[Get Order Info](https://www.bitget.com/api-doc/classic/spot/trade/Get-Order-Info)

Futures 修改价格/数量明确为撤销旧单后异步创建新单，且必须提供 `newClientOid`；这不是原地 amend。[Contract Modify Order](https://www.bitget.com/api-doc/classic/contract/trade/Modify-Order) Spot batch cancel-replace 也可能出现撤单成功、新单失败，不能视为原子操作。[Spot Batch Cancel Replace](https://www.bitget.com/api-doc/classic/spot/trade/Batch-Cancel-Replace-Order)

限流逐 endpoint 按 UID/IP 定义；例如 Spot place 与 batch place、Futures batch place/modify/cancel 的桶不同。WS trade 与 REST 共享配额，且部分 WS trade 能力需要额外权限。[Spot Place Order](https://www.bitget.com/api-doc/spot/trade/Place-Order)、[Contract Batch Order](https://www.bitget.com/api-doc/classic/contract/trade/Batch-Order)、[WS Place Order](https://www.bitget.com/api-doc/spot/websocket/private/Place-Order-Channel)

官方 Demo 使用 demo API key 和 PAP public/private WS。[Demo WebSocket](https://www.bitget.com/api-doc/common/demotrading/websocket) REST demo 的 header、可交易 Instrument 与生产等价性必须逐 endpoint 在准入测试中固定。

## 4. 统一适配器合同

能力声明必须以 `Venue + product` 为粒度，而不是只按 Venue：

| 合同项 | 必须表达的语义 |
|---|---|
| `BookSync` | snapshot 来源、delta 来源、桥接规则、连续字段、checksum 规则、最大深度、序号重置条件 |
| `PrivateStream` | 有哪些事实通道、是否有初始快照、可用实体 ID、顺序保证、是否支持 resume；未确认即 `none` |
| `ClientOrderIdentity` | 格式、最大长度、唯一作用域、查询/撤单能力、官方幂等期限；未确认期限即 `none` |
| `OrderMutation` | `in_place`、`cancel_then_create`、`cancel_replace_partial` 或 `unsupported`；返回旧、新两个订单身份 |
| `Batch` | 最大条数、逐项结果、是否部分成功、每条订单如何计入限流；默认非原子 |
| `RateLimit` | 作用域、操作桶、动态发现/响应 headers、退避与 ban 语义 |
| `Reconciliation` | open orders、order by client/native ID、fills、balances、positions 的分页、时间窗和保留期 |
| `UnknownRecovery` | 可查询身份、等待私有流时限、REST 查询顺序；任何未知不得自动 retry submit |
| `Environment` | production/demo/testnet 的 endpoint、认证、支持产品和已验证差异 |

统一恢复状态机：

```text
Disconnected
  -> 禁止增加风险
  -> 重连公共流并重建每个 L2
  -> 重连私有流
  -> REST 查询 open orders / recent terminal orders / fills
  -> REST 查询 balances / positions
  -> 将差异记录为 ReconciliationBreak
  -> 所有 Unknown 订单得到解释
  -> 仅在 L2 Live、私有流健康、对账无 break 时恢复开仓
```

批量响应必须拆成逐订单 `ExecutionReport`；部分失败不回滚成功项。私有事件按 Venue order ID、client order ID、trade/fill ID 和状态机规则去重，不能按到达顺序覆盖较新的事实。

## 5. 生产准入测试

官方文档不能替代以下可重复测试。每个 Venue 的 Spot 与 USDT Futures 必须分别通过：

1. L2 snapshot/delta 桥接、故意断包、乱序、重复、序号重置及重连重建。
2. 私有流断开期间完成下单、部分成交、成交、撤单、强制仓位/余额变化后，REST 能完整恢复。
3. 客户端订单号重复、终态后复用、查询保留期和作用域；无结论前内部 ID 永不复用。
4. 在请求发出后主动切断连接，覆盖“交易所已受理但客户端未收到响应”，验证 `Unknown -> query -> reconcile`，禁止盲重发。
5. Batch 每项成功/失败、限流计数和部分成功；cancel-replace 或 modify 的旧、新订单身份均可解释。
6. REST order/fill history 的时间范围、分页边界、最大回看窗口与数据延迟。
7. 单向/逐仓切换前置条件、reduce-only、Post-only、IOC/FOK 及规格舍入。
8. Demo/Testnet 与生产 schema、错误码和限流差异形成版本化清单。
9. Gate.io USDT Futures FOK；Bitget Classic/UTA 账户选择及 REST demo；Binance USDⓈ-M testnet 生产等价性。

任一目标订单能力或安全恢复能力未通过，该 `Venue + product` 只能启用行情，不得启用生产下单。

## 6. 延后项

- 不建立“万能订单参数”并静默降级；策略请求 Venue 不支持的语义时明确拒绝。
- 不实现 UTA、组合保证金、双向持仓、币本位或算法单；它们需要新的能力档案。
- 不现在固定 QPS 数值、历史保留期或 batch 大小；这些是会变化的 Venue 配置和准入证据，不是领域常量。
- 不为四家分别发明恢复流程；共同流程就是 L2 重建、私有流重连、REST 对账和 `Unknown` 订单解释，差异只存在于能力档案。
