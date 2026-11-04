# Hyperliquid

本文介绍 Ringwin 的 Hyperliquid Adapter：支持哪些产品和订单、如何接入现有运行链路，以及行情、签名和恢复的边界。内容按 2026-11-04 仓库源码核对。

当前支持范围已取得[离线 Adapter 功能验收](hyperliquid-testnet-qualification.md)。这不表示已经完成真实 Testnet 下单、成交或生产部署；真实 transport 和节点资源装配仍需另行验收。

## 组件与接入方式

Adapter 使用 Zig 实现，沿用项目的执行与公共行情两条接缝，不维护第二套 OMS、风控或账户账本。

| 组件 | 职责 |
| --- | --- |
| [HyperliquidVenueAdapter](../src/adapters/hyperliquid/hyperliquid_venue_adapter.zig) | 通过 `.adapter()` 提供 `VenueAdapter`；处理订单编码、私有事实、查询、对账和恢复 |
| [HyperliquidMarketFeed](../src/adapters/hyperliquid/hyperliquid_market_feed.zig) | 通过 `.adapter()` 提供 `MarketFeedAdapter`；处理单品种公共行情，不持有账户或签名权限 |
| [Signer](../src/adapters/hyperliquid/hyperliquid_signer.zig) | L1 action 编码摘要与钱包签名，绑定资金账户、环境、session 和 fencing token |
| [Runtime](../src/runtime/hyperliquid_runtime.zig) | 接收配置及外部资源，将 Adapter 接到现有 Owner、Gateway、DurableStore、时钟和共享预算 |

执行请求由 Gateway 按 `ExchangeAccountIdentity` 路由，Adapter 输出规范事件，经 Owner 应用到 `TradingShard` 并持久化。公共行情通过独立的 `MarketFeedAdapter` 进入相同权威状态体系。交易所字段留在 Adapter 内部；策略使用项目的 Instrument、Asset 和订单合同。

Transport 由运行节点注入：私有侧提供 `submit_fn`、`query_fn`，公共侧负责发送订阅并将响应交给 feed。现有协议合同选择 REST `/exchange` 发送交易、`/info` 查询，WebSocket 接收实时事实；这不是一个自行建立网络连接的完整客户端 SDK，也没有独立的 Hyperliquid 在线启动 CLI。

## 产品与账户范围

| 产品或模式 | 当前范围 |
| --- | --- |
| 现货 `spot` | 支持明确批准的 token、pair 与 Asset 绑定 |
| 标准线性永续 `isolated_linear` | 支持逐仓；实际结算 Asset、杠杆及账户配置必须匹配已激活规则 |
| Cross、统一或组合保证金 | 不支持 |
| HIP-3、HIP-4 | 不支持 |
| Vault 交易 | 不支持 |
| 主账户、子账户签名绑定 | Signer 区分 `master` / `subaccount`；子账户使用协议的 `vaultAddress` 字段，不代表支持 Vault 产品 |

账户模式必须是当前实现识别的 `default`，永续持仓配置要求 `oneWay` 和 `isolated`。Adapter 报告观察到的账户配置，不在启动时自动修改杠杆或保证金模式；共享 `AdapterRequest` 当前没有这类配置写入命令。

标准永续的结算币按 metadata 与批准的 Asset 绑定核对，不靠显示名称推断。跨所配对要求相同 quote/settle Asset；USDC 与 USDT 不合并。包装现货可通过已批准的 `approved_base_pair` 参与经济敞口比较，但实际资产、费用和账本身份不变，详见[运行接线](hyperliquid-runtime.md)。

## 品种身份与 metadata

Ringwin 不使用 `BTC-USD-PERP.HYPERLIQUID` 这类 Nautilus InstrumentId 字符串作为注册接口。配置必须明确内部 InstrumentIdentity、产品、原生索引、真实资产与数值单位。

| 项目 | Ringwin 绑定规则 |
| --- | --- |
| 永续 `wire_asset` | `meta.universe` 下标，与公共 feed 的 `universe_index` 一致 |
| 现货 `wire_asset` | `10000 + spotMeta.universe[].index`，不是 token index |
| `coin` | metadata 中对应市场的协议名称；非 canonical 现货可能是 `@index` |
| Token → Asset | `Profile.tokens` 提供已批准的 token index 到真实 AssetIdentity 映射 |
| 现货 token 身份 | 公共 Binding 核对 base/quote token index 与 tokenId |
| Metadata 摘要 | `expected_metadata_digest` 必须事先批准；首次收到的响应不能自行成为批准值 |

公共和私有绑定中的品种、产品、coin、价格/数量单位及市场索引必须精确一致。metadata 观察不会自动注册、激活新规则或加载全部市场；不匹配会拒绝处理或撤销相关行情资格。

不要从历史样本复制 BTC、ETH 或某个 `@index` 的索引作为部署常量，也不要因为 token 名为 BTC/UETH 就批准跨所配对。历史公开观察仅见[验收记录](hyperliquid-testnet-qualification.md)，不作为当前配置输入。

## 公共行情

| 数据 | 当前处理 |
| --- | --- |
| `l2Book` | 有限深度快照，按帧替换声明范围；每侧保留前 8 档，超过范围标记截断 |
| `trades` | 公共成交，按来源身份去重并检查冲突 |
| `activeAssetCtx` | 标准永续的标记价、指数价和资金费率等受支持字段 |
| `funding_history` 输入 | 永续历史资金费率解码；不等于账户实际资金费结算 |
| K 线、TWAP、自定义数据客户端 | 当前无对应公共订阅接口 |

`l2Book` 没有可供本实现证明连续性的交易所源序号，不能当成完整 L2 增量簿，也不能用相邻时间戳补造 sequence。策略不能据此推断第 9 档及更深流动性。

每个 feed 有独立 session、subscription 和持久 epoch。断连、超时、坏帧、背压或规则变化会影响行情健康；恢复需要新订阅身份及有效快照。`Binding.max_age_ns` 默认 5 秒，运行节点必须持续驱动 `poll`，包括存在待排空输出时。

公共输入帧上限为 1 MiB，单帧成交上限为 30；公共成交缓存保留 256 个身份。容量不足或过旧事实不能靠静默丢弃、重新计入来维持健康状态。行情的 RawIngress 先持久捕获，再解码和应用。

## 订单能力

| 请求 | 当前支持及约束 |
| --- | --- |
| 限价 GTC | `limit` + `good_til_canceled` → `Gtc` |
| 限价 IOC | `limit` 或 `ioc` + `immediate_or_cancel` → `Ioc`，仍必须给出限价 |
| Post-only | `post_only` + `post_only` → `Alo` |
| Reduce-only | 仅标准线性永续支持 `venue_reduce_only` |
| 撤单 | 按原 CLOID 编码 `cancelByCloid` |
| 查询与对账 | 保留原订单身份、CLOID/oid 和资金账户范围 |
| 市价、FOK、触发单、止盈止损 | 不支持，不自动转换为其它订单 |
| Amend/改单 | 不支持，也不自动实现 cancel-replace |
| 批量下单、TWAP、定时撤单 | 当前没有相应发送接口 |

当前编码器每个 action 发送一张订单或一个撤单，订单使用 `grouping="na"`，不附带 builder 归因。没有 builder 审批脚本或归因开关；带非零 `builderFee` 的成交也不在当前支持范围内。

### 价格与数量

价格和数量走精确十进制及项目整数单位，不经过浮点转换，不自动舍入，也没有参考实现的默认市价滑点：

- 价格必须满足激活规则的 tick；非整数价格最多 5 位有效数字。
- 小数位上限为永续 `6 - szDecimals`、现货 `8 - szDecimals`；整数价格豁免有效数字限制。
- 数量必须满足 `szDecimals` 和项目 lot 单位，且为正值。
- 订单必须有 `limit_price`；当前拒绝附带 `market_protection_price` 的请求。

例如，`123456` 可满足有效数字规则，`12345.6` 不满足；这只是精度示例，不能代替具体品种的 tick、数量及准入检查。

### 订单状态与经济成交

CLOID 为 `0x` 加 32 个十六进制字符，由 Gateway 的 `prepareClientOrderId` 接缝生成并纳入持久发送身份。它用于关联和恢复，不提供任意重发的安全保证。

`orderUpdates` 和 REST action 响应提供订单状态证据。即使响应为 `filled`，其中的总数量、均价和 oid 也不能替代独立成交及费用证据，不据此推断经济 Fill。

实际成交按 Venue、环境、资金账户、品种、时间、tid 和 oid 等组成的事实身份去重。完全重复不再入账；同身份的数量、价格或费用矛盾则失败关闭。OMS 的 `cumulative_quantity` 保留交易所报告累计量，经济账使用唯一已应用的规范 Fill；两者分别维护。

费用按真实 feeToken 绑定资产：正费用输出 fee，已知零费用输出显式零 fee，负费用输出同资产的显式零 fee 与精确正 rebate。缺失费用字段或未知 fee Asset 仍拒绝，不能回退成 quote。`closedPnl` 用于核对交易所报告损益，不重复记为一笔本地损益。未知订单、强平成交、非支持账务或无法归属的事实保留证据并进入安全核对，不伪造策略订单来吸收它们。

私有 adapter 恢复种子的 schema 为 2，拒绝 schema 1；旧种子可能缓存 `fee=null` 的返佣语义，不自动迁移。Canonical Fill、journal 和核心 snapshot 的字段布局不变；同一负费用 RawIngress 在新解码器下产生的规范输入和摘要已改变，旧解码结果及资格证据不能直接沿用。

## 钱包、环境与权限

资金账户地址用于账户查询和私有订阅，agent 钱包地址用于签名；查询不会回退到 agent 地址。凭证、资金账户、环境或 session 改变时必须按既有生命周期重新绑定。

Signer 经现有 `CredentialStore` 使用受保护钱包资源，并在返回签名之前持久消费 nonce。签名结果不是发送授权：Gateway/Adapter 仍检查原请求的权限、期限和 fencing token，实际提交前再次校验。

Runtime 只接受以下资源模式：

| 模式 | 资源与权限 |
| --- | --- |
| `offline` | 脱敏 fixture transport 和 authorizer，无真实凭证加载路径 |
| `read_only` | Testnet transport，无钱包签名能力 |
| `testnet_write` | Testnet 钱包、匹配的资金账户/session/lease，加上显式 `hyperliquid_testnet_write_authorized` 和未到期的单调时钟期限 |

主网不在当前 runtime 支持范围内，不能使用 OKX Demo 开关授权 Hyperliquid。Runtime 不读取 `HYPERLIQUID_PK`、`HYPERLIQUID_TESTNET_PK` 或 Vault 环境变量；凭证输入、网络连接和主备资源由现有节点生命周期提供。

## 配置与运行接线

配置入口是 `Configuration.parse(allocator, bytes, expected_sha256)`。控制面先选择不可变配置 artifact 及批准摘要，节点再校验原始字节并持有解析结果直到 runtime 退出。

| 配置项 | 要求或默认值 |
| --- | --- |
| `schema` | `1` |
| `epoch_startup` | 默认 `recover`；只有首次创建流时明确使用 `virgin` |
| `profile` | 明确 Venue、ExchangeAccount、资金账户、环境、session、版本、私有 bindings 及 token 绑定 |
| `profile.can_read` / `can_trade` | 配置要求 `true` / `false`；写权限由运行资源与 Owner/Gateway 准入决定 |
| `feeds` | 1–8 个品种，与私有 bindings 一一对应 |
| `feeds[].subscription_set` / `session` | 非零且互不重复 |
| `feeds[].binding.expected_metadata_digest` | 非零的事先批准摘要 |

规则、Asset 和 capability 必须已由 Owner 提交；单独构造 Adapter 或把配置中的 `can_trade` 改为 `true` 都不能获得交易授权。具体资源所有权、epoch/generation 恢复及跨所策略接线见[Hyperliquid 运行接线](hyperliquid-runtime.md)。

## 限流与发送失败

`hl.Budget` 是注入的共享 60 秒窗口预算，默认 `limit=100`，实现接受的范围为 2–1200。普通请求保留最后 1 个权重供撤单使用；它不是完整的交易所全局限流器。

同一出口的私有查询、写入及公共请求应使用同一预算。节点还需协调其它进程/客户端及真实 WebSocket、地址级配额；不能给每个账户各建一份预算后声称已经覆盖共享 IP 限制。

Transport 必须区分三个结果：

| 结果 | 含义与处理 |
| --- | --- |
| `proven_before_send` | 能证明尚未发送，按未发送结果返回 |
| `response` | 已收到响应，仍需校验响应内容及对应订单 |
| `uncertain` | 不能证明交易所是否接收，保留 Unknown 并对账 |

超时、断线或不完整响应不能自动变成拒单，更不能换 nonce 重新签名重发。Unknown 保留原身份、风险及周期占用；重连和重启都不能清除这些占用。当前不提供 Nautilus 的 HTTP 重试次数、退避、代理或 WS post 配置选项。

## 对账与恢复

私有恢复覆盖账户模式、永续/现货账户状态、开放订单、历史订单、成交、资金费及账务历史查询。恢复固定账户、环境、旧 session 和时间窗口，记录每页证据与终止原因；分页重叠通过事实身份去重。

当前有明确的完整性限制：

- REST 可访问集合耗尽不证明完整历史保留，也不构成原子账户快照；`RecoveryCoverage.complete` 保持 `false`。
- `unknownOid`、空开放订单或短历史页不能证明 `ConfirmedAbsent`。
- 当前拒绝实际资金费与非成交账务流水；有查询入口不等于支持入账。此类事实、同毫秒满页无法前进、预算耗尽或超时，都不能伪装为恢复成功。
- 私有 checkpoint 保留 64 个订单关联、128 个事实身份；恢复覆盖记录最多 16 页。达到边界必须保留缺口，不能覆盖旧证据。

恢复沿 RawIngress、Adapter checkpoint、Owner 快照及日志尾部应用继续。回放不签名、不查询、不发送，也不重新发放权限；`resumeReadOnly` 仍保留恢复要求。公共回放同样校验原配置摘要和持久捕获身份，不能用新配置解释旧流。

## 离线验证

在仓库根目录、使用项目固定 Zig `0.17.0-dev.315+5b647b792` 执行：

```powershell
# Runtime 与模拟对手的离线接线
zig build run -Doptimize=ReleaseSafe -- --hyperliquid-offline

# Adapter、行情、Gateway→Owner、权限及恢复定向验收
python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -O ReleaseSafe --test-filter Hyperliquid --stack 67108864

# 完整离线回归（修改实现时按影响范围运行）
zig build test -Doptimize=ReleaseSafe
```

这些命令不连接真实账户，也不产生真实成交。已记录的执行结果、源码身份及公开只读观察见[Adapter 功能验收记录](hyperliquid-testnet-qualification.md)；本文新增不构成一次重新验收。

## 进一步阅读

- [Adapter onboarding](integrations/adapter-onboarding.md)：共享接缝及新 Venue 的接入规则。
- [ADR 0001](adr/0001-separate-venue-execution-and-market-feed-seams.md)：执行与行情的职责边界。
- [首期协议合同](research/2026-11-02-hyperliquid-protocol-contract.md)：协议来源及字段处理原则，包含设计目标，不等于所有目标都已实现。
- [公共行情依据](research/2026-11-02-hyperliquid-public-market.md)、[签名与历史依据](research/2026-11-02-hyperliquid-signing-history.md)：固定来源与边界说明。
- [字段处置矩阵](venue_field_disposition_matrix.md)：交易所字段到项目合同的详细映射。
