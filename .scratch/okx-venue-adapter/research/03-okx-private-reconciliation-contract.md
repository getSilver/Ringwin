# OKX 私有事实与对账字段契约

研究日期：2026-08-11（UTC）
范围：第 07 票所需的 `BTC-USDT` SPOT 与 `BTC-USDT-SWAP` 私有事实；只查 OKX 当前官方 API 文档和官方 API 技巧页，不使用账户凭据。

## 结论

OKX 没有提供把某次 REST 查询与私有 WS 流绑定到同一原子时点的 snapshot token。`orders` 订阅也没有初始快照。因此安全实现不能把“订阅成功”或一次 REST 返回当作启动完成；必须先订阅并原样缓冲 WS，再拉 REST bootstrap，按端点身份键合并，排空缓冲，并做一次稳定性复核。任何缺页、身份冲突或无法解释的迟到事实都应保持 reconciliation barrier 关闭，禁止新增风险。这是根据官方接口性质得出的实现约束，不是 OKX 对原子快照的承诺。[Orders channel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-order-channel) [官方对账与分页说明](https://www.okx.com/docs-v5/trick_en/)

## 1. 订阅与 REST bootstrap

启动和每次重连使用同一流程：

1. 登录 private WS，订阅 `orders`（SPOT 与 SWAP）、`account`、`positions`（SWAP），逐项等待 subscribe ACK；从登录后的首个 ingress 开始记录连接世代、接收序号、接收时间和原始帧。
2. 在 barrier 内缓冲所有业务 push。`orders` 没有 initial push；`account` 和 `positions` 会给 `eventType=snapshot`，大快照可能分成 `curPage/lastPage` 多页。一个频道只有收齐从首个 snapshot 页到 `lastPage=true` 才形成完整候选快照；此前到达的 `event_update` 继续缓冲。[Account channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-account-channel) [Positions channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-positions-channel)
3. 拉 `GET /api/v5/account/config`、`account/balance`、`account/positions`、`trade/orders-pending`，以及覆盖断线窗口的 `trade/orders-history`/`orders-history-archive` 和 `trade/fills`/`fills-history`。所有分页必须拉到空页或短页，并保留每页请求游标与 RawIngress。
4. 先合并 REST 和已完成的 WS snapshots，再按本地 ingress 顺序应用缓冲的事件更新；随后重读 pending、balance、positions 并排空新缓冲。只有两轮结果可由同一事实集合解释、没有丢页/冲突/未知订单，barrier 才可开放。

第 4 步的“双读至稳定”是必要的客户端收敛算法：官方没有跨 REST/WS 的一致性水位，也没有为 `account/config` 返回 venue 版本。实现不得伪造一个 OKX snapshot sequence。

## 2. Orders 与 ExecutionReport

`orders` WS 和 REST order/list/history 的核心字段合同为：

- 身份与关联：`instType`, `instId`, `ordId`, `clOrdId`, `reqId`, `tag`。
- 原始意图：`tdMode`, `ccy`, `tgtCcy`, `side`, `posSide`, `ordType`, `px`, `sz`, `reduceOnly`, `category`。
- 当前状态：`state` (`live`, `partially_filled`, `filled`, `canceled`, `mmp_canceled`), `accFillSz`, `avgPx`, `pnl`, `fee`, `feeCcy`, `rebate`, `rebateCcy`, `cancelSource`/`cancelSourceReason`。
- 本次成交：`tradeId`, `fillPx`, `fillSz`, `fillPnl`, `fillTime`, `fillFee`, `fillFeeCcy`, `execType`。REST order 信息与 WS orders 对这些 fill 字段的定义不同，必须保留来源，不能共用一个含混的“最新成交”覆盖槽。
- 时间与错误证据：`cTime` 是通过风控后的创建时间，`uTime` 是改单、成交或撤单后的更新时间；请求响应另有 gateway 微秒 `inTime/outTime`。WS push 的逐条 `code/msg` 也应原样保留。[Order fields and states](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details) [Order timestamps](https://www.okx.com/docs-v5/trick_en/#order-timestamp)

身份规则：

- `ordId` 是 OKX 全局唯一订单 ID，是订单主键；`clOrdId` 只保证所有 pending 订单间唯一，订单终态后可复用，故只能作关联键。若查询同时给两者，OKX 优先 `ordId`；复用过的 `clOrdId` 查询只返回最近一笔。[Identifiers](https://www.okx.com/docs-v5/trick_en/#identifiers) [Get order details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details)
- 官方明确允许 Orders channel 在异常情况下重复推送相同消息，甚至 `uTime` 不同。若 `tradeId` 非空，按 `(instId, tradeId)` 只处理一次；无 `tradeId` 的 `filled` 按 `ordId` 只接受首个终态；`canceled/mmp_canceled` 同样按 `ordId`；`reqId` 非空的改单结果按永久唯一 `reqId` 只处理一次。[Order channel revamp](https://www.okx.com/docs-v5/log_en/#order-channel-revamp)
- 对普通非终态更新，官方没有事件 ID。建议以 `ordId + state + accFillSz + reqId + tradeId + 业务字段哈希` 识别语义重复，同时保存每个原始观察；不能仅凭 `uTime` 去重。相同官方身份键出现不同不可兼容内容时是 `identity_conflict`，不是 last-write-wins。

## 3. Fill

REST `trade/fills`（近 3 天）与 `trade/fills-history`（近 3 个月）至少保留：`instType`, `instId`, `tradeId`, `ordId`, `clOrdId`, `billId`, `subType`, `tag`, `fillPx`, `fillSz`, `fillIdxPx`, `fillPnl`, `fillTime`, `ts`, `fee`, `feeCcy`, `execType`, `side`, `posSide`, `tradeQuoteCcy`。`fillTime` 是实际成交时间，`ts` 是系统生成该 fill 记录的时间；排序成交应使用 `fillTime`。[Transaction details](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-transaction-details-last-3-days)

- 官方定义 `billId` 全局唯一，`tradeId` 仅在 `instId` 内唯一；产品 Fill 主键用 `(instId, tradeId)`，同时把 `billId` 作为 REST 账单证据和分页键。两种键映射冲突必须失败关闭。[Identifiers](https://www.okx.com/docs-v5/trick_en/#identifiers)
- 不依赖 VIP4 才可用的 private `fills` WS：它无初始数据、taker 可聚合，且不覆盖 liquidation、ADL 等若干事件。第 07 票以 Orders WS 加 REST fills 为完整路径；若以后订阅 fills，只能作低延迟补充。[Fills channel](https://www.okx.com/docs-v5/en/#order-book-trading-trade-ws-fills-channel)
- liquidation/ADL 的 fill `tradeId` 可能为负，订单侧可能为 `0`；解析器必须支持有符号十进制 ID 字符串，不把 `<=0` 一概视为缺失。

## 4. Balance、Margin 与 account channel

OKX 没有独立的“margin snapshot”接口。`ExchangeMarginSnapshot` 应来自同一条 `account/balance` 或 WS `account` 账户对象，不能把稍后单独读取的字段拼成伪原子快照：

- 账户级：`uTime`, `totalEq`, `isoEq`, `adjEq`, `availEq`, `ordFroz`, `imr`, `mmr`, `borrowFroz`, `mgnRatio`, `notionalUsd`, `notionalUsdForSwap`, `notionalUsdForFutures`, `notionalUsdForOption`, `notionalUsdForBorrow`, `upl`。
- 币种级 `details[]`：`ccy`, `eq`, `cashBal`, `uTime`, `isoEq`, `availEq`, `disEq`, `availBal`, `frozenBal`, `ordFrozen`, `liab`, `upl`, `uplLiab`, `crossLiab`, `isoLiab`, `mgnRatio`, `imr`, `mmr`, `interest`, `twap`, `eqUsd`, `borrowFroz`。字段不适用于账户模式时可能是空字符串，空值与数值零必须区分。[Get balance](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-balance)

WS `account` 的 initial/regular snapshot 只含非零余额；event update 只含受影响币种，但包括变为零的币种。REST 不带 `ccy` 也只列非零资产；显式 `ccy=BTC,USDT` 时，只要账户曾持有该币，零余额也会返回。因此本票固定范围应显式查询配置的 BTC、USDT，并以 `(uid, ccy)` 为余额实体键；`details[].uTime` 和完整字段哈希用于重复/冲突检测，而不是把“未出现”解释为零。[Account snapshot semantics](https://www.okx.com/docs-v5/trick_en/#account)

账户对象和币种 detail 没有官方事件 ID。每个 snapshot 要以 `connection_generation + snapshot page set + raw hash` 留证；同一 `(ccy, uTime)` 内容不同视为冲突。账户级 Margin 与该次账户对象的所有 `details` 共用一个 observation，不能拆开后按各自最新时间重组。

## 5. Position

`account/positions` 与 WS `positions` 对 SWAP 至少保留：`instType`, `instId`, `mgnMode`, `posId`, `posSide`, `pos`, `ccy`, `posCcy`, `availPos`, `avgPx`, `markPx`, `upl`, `uplRatio`, `lever`, `liqPx`, `margin`, `imr`, `mmr`, `mgnRatio`, `notionalUsd`, `adl`, `tradeId`, `cTime`, `uTime`, `pTime`。价格、盈亏和风险值会因 mark 变化而定期更新，不能把每次定时 push 误判为新成交。[Get positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions) [Positions channel](https://www.okx.com/docs-v5/en/#trading-account-websocket-positions-channel)

- 官方说明 `posId` 由 `mgnMode + posSide + instId + ccy` 组合生成，长期平仓、账户模式或持仓模式变化后可能生成新 ID。因此领域实体键使用 `(instId, mgnMode, posSide, ccy)`，`posId` 是需保留和校验的 venue incarnation。
- WS initial/regular snapshot 只推非零仓位；event update 会推仓位归零。REST 不指定 `instId/posId` 时不返回零仓位；指定仍有效的 `instId` 或曾打开过且未过期的 `posId` 才能核实零。`posId` 在最后一次完全平仓超过 30 天后会清除。[Position ID and zero semantics](https://www.okx.com/docs-v5/trick_en/#positions)
- `tradeId` 只可辅助 order-fill/position 对账：多个成交可聚合成一次 position 更新；liquidation/ADL 不一定产生 order update，且其 position 更新可能不改变 `tradeId`。比较时还必须使用 `pos` 与 `uTime`；相同 `tradeId` 但更新的 `uTime/pos` 不能丢弃。[Fill-position reconciliation](https://www.okx.com/docs-v5/trick_en/#reconciliation-between-fill-and-positions)

## 6. Account configuration

`GET /api/v5/account/config` 无请求参数、无分页，至少版本化：`uid`, `mainUid`, `acctLv`, `acctStpMode`, `posMode`, `autoLoan`, `enableSpotBorrow`, `ctIsoMode`, `mgnIsoMode`, `greeksType`, `feeType`, `level`, `levelTmp`, `perm`, `label`, `ip`, `kycLv`, `spotRoleType`, `spotOffsetType`，以及响应中出现的任何未知字段。当前范围的硬门槛是预期账户模式、`posMode=net_mode`、trade permission 与 Demo endpoint 一致。[Get account configuration](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-account-configuration)

该响应没有配置版本或更新时间；`VenueAccountConfigurationSnapshot` 必须使用本地 RawIngress 时间/哈希作为 evidence version，并在每次启动、重连和配置相关拒单后重读。字段变化先关闭新增风险，再重新核对规则与持仓。

## 7. 逐 endpoint 分页与去重

| Endpoint | 窗口/排序 | `after` 游标（向旧） | `before` 游标（向新） | 页内/跨页主去重键 |
|---|---|---|---|---|
| `trade/orders-pending` | 当前未完成，返回 `live/partially_filled` | `ordId` | `ordId` | `ordId` |
| `trade/orders-history` | 最近 7 天；未成交撤单仅 2 小时 | `ordId` | `ordId` | `ordId`，保留状态 observation |
| `trade/orders-history-archive` | 最近 3 个月 | `ordId` | `ordId` | `ordId`，保留状态 observation |
| `trade/fills` | 最近 3 天，最新在前 | `billId` | `billId` | `billId`，并校验 `(instId,tradeId)` |
| `trade/fills-history` | 最近 3 个月，最新在前 | `billId` | `billId` | `billId`，并校验 `(instId,tradeId)` |
| `account/positions-history` | 最近 3 个月，按 `uTime` 倒序 | `uTime` | `uTime` | 领域 position key + `posId/uTime` + 内容哈希 |

这些端点默认/最大 `limit=100`。`before/after` 边界不包含游标记录；当同一 `uTime` 有多条 position-history 记录时，时间游标没有稳定 tie-breaker，不能声称无损翻页。这是官方 schema 的剩余歧义：本票实时当前仓位使用无分页的 `account/positions`；若未来依赖 position history 完整回放，需要实测同毫秒多记录及重叠时间窗策略。[Pagination](https://www.okx.com/docs-v5/trick_en/#pagination) [Position history](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions-history)

分页器必须逐 endpoint 声明游标字段，不允许用一个猜测型通用 paginator。每页检查顶层 `code/msg`、游标单调向旧、末项游标推进；跨页重复允许幂等丢弃，但同一身份键内容冲突、游标不推进或满页后请求失败都使 bootstrap 不完整。

## 8. 尚存歧义与资格证据

- 官方没有 REST/WS 原子 watermark，也没有说明多页 account/positions snapshot 的 snapshot ID；实现只能依赖单连接有序 ingress、`curPage/lastPage` 和 REST 稳定复核，并对重叠/重启 snapshot 世代失败关闭。
- `uTime` 不是唯一事件键；官方甚至明确 Orders duplicate 的 `uTime` 可不同。所有实体都要保存原始 observation，冲突不可用 last-write-wins 隐藏。
- 空字符串、字段缺失与 `"0"` 语义不同；资格样本需覆盖 Demo 当前 `acctLv/posMode` 下的实际可用字段矩阵。
- 需用 Demo 资格运行记录：三频道 subscribe ACK、account/positions 多页形态（若可制造）、REST 每页首尾游标、同一 fill 在 Orders 与 REST 的字段差异、归零余额/仓位以及断线期间成交。证据不得包含 key、secret 或 passphrase。
