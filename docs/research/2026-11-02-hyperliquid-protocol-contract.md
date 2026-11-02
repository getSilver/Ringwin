# Hyperliquid 首期协议合同与实施交接

日期：2026-11-02。源码基线：`3265db098340ad4d6b7b3ff47baeaff108229341`。
范围：[01](../../.scratch/hyperliquid-adapter/issues/01-protocol-field-contract.md)。
这是 decoder、共享合同及验收的输入，不是已实现的 CapabilityProfile 或交易资格。

## 依据与证据身份

主要参考用户提供的 `D:/github/nautilus_trader/docs/integrations/hyperliquid.md`，本地 revision
`64bb2b8526fd66964125b40b5bbf0af060ed120a`；文件 SHA-256、查询 UTC 和官方补查内容的
SHA-256 见 [sources.json](../../src/testing/fixtures/hyperliquid/sources.json)。以文件内容身份为准，
该 revision 不保证外部工作区无修改。Nautilus 的账户余额回退、推断 Fill、默认价格舍入、builder
归因和在线验收结论均不继承。补查仅用于其省略的 wire 字段、签名、身份及历史边界。

| 简称 | 官方补查来源及用途 |
|---|---|
| P | [永续](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals)：metadata、逐仓状态、资金费 |
| S | [现货](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/spot)：token、pair、账户余额 |
| I | [Info](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint)：订单、成交、历史覆盖 |
| W | [WS subscriptions](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions)：消息字段、快照、成交身份 |
| E | [Exchange](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint)：请求、CLOID、响应 |
| T | [Tick/lot](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/tick-and-lot-size)：精度合法性 |
| N | [Nonce/API wallet](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets)：signer 与资金账户 |
| R | [限流](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/rate-limits-and-user-limits)：真实共享范围 |

签名的固定 SDK 版本、测试向量和历史字段的进一步核对见
[签名与历史依据](2026-11-02-hyperliquid-signing-history.md)。官方页面没有稳定协议版本号；
记录下载内容哈希，未来变化必须重新审核，不能把访问日期当协议版本。

## 身份、产品与准入

每个执行 session 固定绑定 `(VenueIdentity, environment, ExchangeAccountIdentity,
funding account address, agent public address, credential version)`。这些注册身份由现有配置/Owner
路径分配，01 不占用任意整数作为正式 Venue ID。Testnet 和主网不能共享市场索引、凭证、
CapabilityProfile 或资格。资金地址和 agent 地址均为规范小写 20-byte 地址的文本表示；前者用于
所有 `user` 查询/私有订阅，后者只签名。缺资金账户绑定即拒绝启动，禁止回退到 agent。（N）

标准永续的 wire asset 为 `meta.universe` 下标，结算 token 从 `collateralToken` 经同环境
`spotMeta.tokens` 解析。现货 wire asset 为 `10000 + spotMeta.universe[].index`，不是 token
index；非 canonical pair 的 wire coin 使用返回的 `@index`。Instrument 绑定 Venue、环境、产品、
pair/perp 索引、真实 base/quote/settle Asset 和规则版本，不能用显示名称作身份。（E、S）

Asset 的 Venue 绑定至少记录 token index、tokenId、链/桥接来源和证据版本。`weiDecimals` 是
协议 metadata，不自动成为已激活 AssetDefinition 的原子精度；`szDecimals` 只约束下单数量。
`isCanonical`、`fullName`、EVM 地址和名字均不能单独授予跨所经济敞口配对资格。
包装资产保持独立 Asset，只有配置明确批准才能用于敞口匹配；不允许兑换、跨链或余额合并。
永续参考标的 BTC/ETH 也不等同于同名现货 token。（S、ADR 0022）

本次公开 Testnet 样本（2026-11-02 05:31 UTC）复核结果：

| 对象 | 观察到的身份与规则 | 尚不能证明 |
|---|---|---|
| BTC 永续 | universe[3]，szDecimals=5，maxLeverage=40，marginTableId=54 | 实际账户逐仓/杠杆、下单资格 |
| ETH 永续 | universe[4]，szDecimals=4，maxLeverage=25，marginTableId=53 | 同上 |
| USDC | collateralToken=0，tokenId=`0xeb62eee3685fc4c43992febcd9e75443` | 主网等价身份或跨资产抵押 |
| UETH/USDC | pair `@1137` / index 1137，tokens [1242,0]；tokenId=`0xe4371d8166f362d6578725f11e0a14f3` | 桥接经济身份批准、流动性 |
| 名为 BTC 的现货 | pair `@50`，token69，tokenId=`0x286820da26c94f1e0ff1e436238f2384`，非 canonical | 是获准 BTC 资产；没有 UBTC 名称匹配不能替代身份核验 |

仅现货及标准线性永续逐仓；同 quote/settle Asset 配对。USDC 与 USDT 分账，不增加汇率交易。
拒绝 cross、统一/组合保证金、HIP-3、HIP-4、vault、未知账户模式和未批准包装资产。
metadata 的 `onlyIsolated`/`maxLeverage` 不能证明账户当前配置。目标模式/杠杆由现有控制面拥有，
Adapter 只执行已授权的受支持动作、报告实际配置，不在连接时自动更新。（P、ADR 0022）

## 消息入口与 transport

Testnet REST 为 `https://api.hyperliquid-testnet.xyz`，WS 为
`wss://api.hyperliquid-testnet.xyz/ws`；主网端点只作为环境区分依据，本期不访问交易接口。
首期选择 REST `POST /exchange` 发单/撤单，`POST /info` metadata/bootstrap/对账；
WS 订阅公共与私有实时事实。暂不实现 WS post，避免两套发送结果关联。该选择不把 REST
和 WS 对同一事实当作不同成交；未来增加 WS post 必须保留相同 Unknown 合同。（用户参考资料）

| 范围 | 计划读取/发送的消息 | 合同边界 |
|---|---|---|
| 产品/规则 | `meta`, `spotMeta`, `tokenDetails`, `metaAndAssetCtxs` | 观察不激活规则；不自动加载其它产品 |
| 公共行情 | `l2Book`, `trades`, `activeAssetCtx`；REST `l2Book`, `recentTrades`, `fundingHistory` | 无完整成交历史能力；参考价分开保留 |
| 发送 | `order`, `cancel`, `cancelByCloid` | Gtc/Ioc/Alo；永续 reduceOnly；grouping=na；无 builder |
| 订单查询 | `orderStatus`, `openOrders`, `frontendOpenOrders`, `historicalOrders` | 按原 CLOID/oid 和资金账户对账 |
| 私有实时 | `orderUpdates`, `userFills`, `userFundings`, `userEvents`, `userNonFundingLedgerUpdates` | 快照不代表无界历史；独立 Fill/账务去重 |
| 账户/配置 | `clearinghouseState`, `spotClearinghouseState`, `userAbstraction`, `userRateLimit`；WS `clearinghouseState`, `spotState`, `activeAssetData` | 账户模式、每品种逐仓杠杆和权限证据缺一不可 |
| 补回 | `userFillsByTime`, `userFunding`, `userNonFundingLedgerUpdates` | 查询窗口、分页及截断证据必须随恢复输出 |

字段逐项处置见[共享矩阵 §3.8](../venue_field_disposition_matrix.md#38-hyperliquid首期协议合同)，
矩阵中的 C 是目标语义，不声称当前共享结构已经能无损表达。

## 数值、订单和经济事实

价格/数量以十进制文本精确解析，不经过 float。有效价格同时满足：最多 5 位有效数字（整数
价格豁免此项）、小数位不超过 `6 - szDecimals`（永续）或 `8 - szDecimals`（现货）。
数量必须是 `10^-szDecimals` 的正整数倍。输出价格去除尾零；不合法输入拒绝，不套用
Nautilus 的 5 位舍入或默认滑点。例：`123456` 合法，`12345.6` 不合法；perp szDecimals=1
时 `0.01234` 合法、`0.012345` 不合法。（T）最小名义/数量、价格保护与 margin tier 需绑定
实际规则证据；本票不凭空给 spot/perp 共用一个最小值。mark/oracle 观察价格不套下单价的
5 位限制；现有单位无法精确表示时保留原文并撤销相关资格，不偷偷舍入。

CLOID 为 `0x` 加 32 个 hex 字符，使用 Gateway 已有 `prepareClientOrderId` 纯编码扩展点，
绑定 namespace/account/order identity 并在发送前持久化；格式校验、编码碰撞和重启重现由 05
验证。不是 Venue 去重/重发保证。下单 action 的顺序、nonce 和签名见签名依据；不借 nonce
代替 CLOID 或业务身份。（E）

`orderUpdates` 报告 origSz/剩余 sz，可精确相减时形成报告累计量，不能据此生成 Fill。
REST action `resting`/`filled` 是订单证据；`filled.totalSz/avgPx/oid` 没有独立成交与费用身份，
不能转成经济成交。IOC 零成交拒绝、部分成交后剩余终结分别处理；filled 的 reduce-only
可能小于原申请量，禁止照抄 Nautilus clamp 或推断成交。无法证明的终态数量交给 05/06
对账，保留原订单条款与事实证据。（E、用户参考资料）

状态翻译使用官方完整枚举的显式表：`open` 在完整数量证据下映射 accepted 或 partially_filled，
`filled` 映射 filled 仍要求数量合同可表达；`canceled`、marginCanceled、openInterestCapCanceled、
selfTradeCanceled、reduceOnlyCanceled、delistedCanceled、liquidatedCanceled、scheduledCancel
映射 canceled 并保留原始原因；`rejected` 及已列明的 `*Rejected` 状态映射 rejected，
`iocCancelRejected` 只表示零成交 IOC 拒绝，不把部分成交余量终结改为 rejected。
triggered、siblingFilledCanceled、vaultWithdrawalCanceled 等范围外状态保留证据并触发安全核对，
不能接受未来所有以 Rejected/Canceled 结尾的字符串。未知 enum 一律不猜；具体 canonical
reason 对照由 05 测试固定，不用他所错误码代替。（I）

成交复合键固定为 `(Venue, environment, funding account, product/instrument, time, tid, oid)`；
公共 trade 的官方全局键至少为 `(time, coin, tid)`，tid 单独不足。把同一复合键的 REST/WS
内容规范化再比较：完全重复 no-op，qty/px/fee 等矛盾失败关闭，不能在键中加入内容 hash
来绕过去重。hash 是链交易证据，不单独作成交 ID。CLOID 不在 fill 时按已持久 oid 映射
归属；不认识的订单/外部成交不可随意归给策略。（W、I）

`fee > 0` 为费用，`fee < 0` 为 rebate，零仍携带真实 feeToken；未知 fee Asset 即使金额零
也不得回退成 quote。builderFee 已含在 fee，不重复记账。`closedPnl` 是交易所报告损益，
与本地成本推导核对，不作第二笔 PnL 入账。源时间毫秒 checked 乘 1,000,000 到 ns；
数量是 base 单位，价格是 quote/base，fee/closedPnl/usdc 均按各自真实 AssetDefinition 转 atoms。
`funding` 是费率而非资金流水，`userFunding.usdc` 才是有符号结算金额。小数费率不能精确
转换为当前 ppm 时明确缺口，不舍入。未知字段保留 RawIngress；影响安全/经济的未知 enum
拒绝映射并对账。（W、P）

强平摘要 lid 没有独立数量/价格/费用，不伪造 Fill；完整强制成交才可生成 VenueForcedExecution，
不创建虚假 Order。`liquidation.method=backstop` 不单独等同所有 ADL；`dir=Auto-Deleveraging`
及链上清算元数据须联合核对。账务 liquidation 与 fill-level liquidation 必须关联避免重复。
字段不足或不能唯一归属时保持 ReconciliationBreak 和经济缺口，不能丢弃风险事实。（用户参考资料、W）

## RawIngress、顺序与恢复证明

每个 REST/WS 输入在解码前持久捕获原始响应字节、路由、Venue/环境/账户/session、
source stream、捕获序号、receive/monotonic/audit 时间和 SHA-256；一个帧可派生多条规范事件，
事件身份与 SourceFactIdentity 分离。请求侧只记录无秘密的请求类型、资金地址、市场、查询窗口
和关联身份，不保存私钥、signature 或完整已签名请求。分页证据关联响应 RawEvidenceRef。
沿用 DurableSink/Owner 应用路径；捕获失败停止该输入，不输出假成功。

每次重连/来源顺序重置建立新 VenueSourceStreamIdentity，稳定持久 StreamIdentity 和
StreamSequence 继续递增。local capture sequence 只证明本地接收顺序；不能填成交易所源序号
或 previous_sequence 来声称行情连续。`l2Book` 是无源序号的有限深度快照，每帧替换声明范围，
每侧仅保留前 8 档并标截断；不构造 delta、不外推第 9 档、不把时间相邻当连续性。（W、当前源码）
掉线/超时/坏帧/规则变更先撤销健康，重连须新快照；shared sequence evidence 由 02 明确后
04 才能把它接入权威市场投影。

恢复查询需固定 `(account, environment, product/instrument scope, old session, [start,end])`，
从持久经济边界到固定 end 的 REST 历史与 WS 缓冲衔接，经去重后核心应用。不同 REST 查询
并非同一原子快照；不能把账户余额和 openOrders 的两个时间点宣称为共同屏障。
`isSnapshot=true` 仅表示该 WS 订阅初始集，不承诺覆盖停机期间或所有成交。

历史实际边界及页容量见签名与历史依据。总原则：inclusive 时间游标重叠查询并按事实键去重，
保存每页请求/响应、最小/最大时间、上限命中和终止原因。满页且同毫秒没有可验证前进方式时
保持 truncated/Unknown，禁止直接 timestamp+1 跳过记录。空页/短页只可能证明请求窗口内的
可访问集合耗尽；最近 N 条历史保留限制、错误行、未知资产、超时或页预算耗尽仍使完整性失败。

ConfirmedAbsent 同时要求旧发送会话静止、可见性延迟依据、订单/终态/成交/资金费及相关经济
历史完整、身份匹配和窗口覆盖。`unknownOid`、空 openOrders、短 history 或一次“没找到”
均不满足；当前没有完整可见性证明，06 默认 unresolved。Unknown 继续保留身份、风险及周期
占用，不换 nonce 重发，不因重连或重启重建业务订单。（I、GLOSSARY）

## 限流、失败与重试

真实限制按出口 IP 聚合，不能只按对象、账户或进程限流：REST 1200 weight/min，exchange
权重 `1 + floor(batch_length/40)`；常见状态/book 查询 2，userRole 60，其它 info 20，
部分历史另按返回条数收费。WS 的连接、新建连接、订阅、unique users、outbound 和 inflight
限额同 IP 共享；具体数值见 R。地址动作预算另行共享，batch 的 n 项消耗 n 个地址动作额度；
signer nonce 共享范围与资金地址限流范围不同。部署必须协调同 IP 的其它客户端或明确拒绝
超出可控预算；本地 limiter 不能宣称掌握全局交易量/拥塞额度。（R）

限流等待/退避消耗原 deadline；队列、页数、帧、批量与每轮工作均有界，保留撤单预算。
只读 info 可在 deadline/预算内按 Retry-After 或有界退避重试，失败不能变为空成功。
发送侧只有 transport 明确证明未开始写入才允许沿原请求继续；写入开始后的断开、超时、
不完整/未知响应一律 Unknown 并对账，不重新签名重发。明确 error 可拒单，但批量响应必须
按项验证数量与对应关系，部分成功不宣称整体失败或原子性。（用户参考资料）

## 改动交接与验收边界

| 切片 | 当前源码证据、后续触及范围 | 必须验证；未证明能力 |
|---|---|---|
| 02 产品/资产 | `model/canonical_event.zig` Product 只有 spot/isolated_linear_usdt；`trading/trading_shard_event.zig` InstrumentRules、MarginRules；instrument/asset registry、risk、portfolio | 真正 USDC atoms/结算、同资产跨所；codec/journal/snapshot/digest/schema 同步；OKX/Binance/Bybit/Simulated 回归 |
| 02 行情/规则 | `canonical_event.zig` L2 sequence、FundingRatePublished.rate_ppm；`market/market_projection.zig` 本地序号推进即 healthy；price 仅 tick/scale | 表达捕获顺序与连续性证据；有效数字+小数上限在风险前与发送前一致校验；小数 funding rate 精确表示或明确拒绝，不为接入舍入 |
| 02 事实缺口核对 | FundingSettlement.venue_bill_id 为 u64；参考资料 WS funding 无独立 bill ID；账户摘要不等于逐仓可用余额 | 先检查可否用已有 SourceFactIdentity/RawEvidence 精确映射；重复 funding/费用修订/强制执行必须有身份；无证据不得新增枚举假装补齐 |
| 03 凭证 | `security/credential_store.zig` SecretMaterial 固定 api_key/secret_key/passphrase；GatewayLease、secret wrapper、现有 Owner 控制面 | 私钥类型/保护/清零/签名 lease、资金地址绑定、nonce 持久高水位与主备 fencing；无第二套授权入口 |
| 04/05 私有实现 | 新 `src/adapters/hyperliquid/`；现有 VenueAdapter/MarketFeedAdapter；Gateway.prepareClientOrderId | decoder、签名调用、transport、限流；公开接缝、背压、stop；Gtc/Ioc/Alo/reduce-only/cancel；未知枚举拒绝 |
| 06 恢复 | `persistence/raw_ingress.zig`、Owner.applyAdapterBatch、TradingShard.apply、现有 recovery | report→fill 与逆序、重复/冲突/迟到、分页截断、RawIngress 回放、snapshot+tail digest 收敛且零发送 |
| 07 配置/入口 | runtime 注册与账户路由、既有 Web 控制面、strategy 同结算资产约束；`src/entry.zig`/`build.zig`/`tools/` 离线编排 | 新 Venue ID/环境/实际资产显式注册；默认离线不读秘密；现有双 IOC 与 Maker–Taker 不分叉 |
| 08 fixture/在线 | `src/testing/fixtures/hyperliquid/`、contracts/acceptance 对应目录 | 公共样本只有 listing/book；私有协议合成样本不证明签名/成交/恢复或在线资格；BTC/ETH spot 保持 pending |

01 仅新增本研究、共享字段矩阵条目、公开与合成样本及本地票证据；不改变调用方、配置、
入口、共享内存或持久格式。因无 decoder/运行逻辑变更，不新增虚假 adapter test 或 TDD seam。
fixture 必须验证 JSON 可读、SHA-256、样本字段分类和来源/合成标记；全套离线回归按实际运行
结果记录，不能拿现有 Venue 通过来宣称 Hyperliquid 已实现。

必须补查的部署/协议输入：包装 BTC/ETH 的真实经济身份批准及可交易流动性；账户实际
userAbstraction/逐仓/权限；资金费无 bill ID 的冲突键与修订语义；强平/ADL 双来源闭合；
历史保留范围外的补回渠道和可见性延迟证明；规则 min notional/保护及 margin tier 的版本依据。
这些项各由 02/03/05/06/08 完成前保持 Unsupported 或 pending，不阻止关闭“合同与交接”01。
