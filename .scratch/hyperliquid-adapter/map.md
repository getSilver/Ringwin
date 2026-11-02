# Hyperliquid 接入设计

Status: open

## Destination

通过设计访谈明确 Hyperliquid 现货与永续接入，并完成面向跨所交易的 Testnet 闭环。

## Definition of done

- 产品、资产身份、账户与保证金模式、订单和行情能力、恢复语义均有明确合同。
- 离线协议、共享接缝、核心应用及持久恢复验证完成。
- 显式授权后完成 Testnet 下单、撤单、成交、费用、断线对账与重启恢复验收。
- 跨所永续—永续、现货—永续组合具有集成证据；生产资格单独记录。

## Rules

- 2026-11-02 用户确认整体设计与八个切片，授权发布本地实施票；本次只发布计划，未开始实现或授权在线写入。
- 参考用户提供的 Nautilus Hyperliquid 文档；其实现选择与验收结果不作为 Ringwin 合同或资格。
- 遵循根级 GLOSSARY、ADR 0001/0012/0017 和 docs/adapter-onboarding.md。
- 复用现有跨所策略与核心合同；真实共享缺口单列前置任务。
- 只维护本地文档，不同步 GitHub。

## Route

以下八张实施票已按用户确认发布，均为 open、未认领；按依赖逐票推进。

| 切片 | 交付与验收 | 前置 |
|---|---|---|
| [01 协议与字段合同](issues/01-protocol-field-contract.md) | 消息/字段处置矩阵、资产与品种身份、精度及有效价格约束、事实身份、历史覆盖、签名和限流依据；形成脱敏样本及必须补查的协议缺口 | 无 |
| [02 共享领域合同](issues/02-shared-domain-contracts.md) | 支持真实 USDC 结算的线性逐仓；区分捕获顺序与行情连续性证据；必要的通用价格规则。覆盖风险、经济、codec、日志、快照、digest 与既有 Venue 回归，不能仅改枚举名称 | 01 |
| [03 Hyperliquid API 钱包凭证与签名](issues/03-api-wallet-signing.md) | API 钱包私钥的安全凭证表示、资金账户绑定、签名向量、nonce 生命周期、主备 fencing；复用 CredentialStore/GatewayLease，不泄露秘密或创建第二套授权入口 | 01 |
| [04 公共行情](issues/04-public-market-feed.md) | MarketFeedAdapter：品种/规则观察、有限深度快照、市场成交、标记/指数价格、资金费率及健康；公开接缝回放、断连和覆盖范围检查 | 02 |
| [05 订单与私有事实](issues/05-orders-private-facts.md) | VenueAdapter：已确认订单集、CLOID、发送结果、私有报告/Fill/账户事实、背压和限流；覆盖拒单、部分成交、重复/冲突及两种 report/fill 顺序 | 02、03 |
| [06 对账与恢复](issues/06-reconciliation-recovery.md) | 启动/重连/重启、Unknown、历史分页与截断、账户和经济事实完整性；公开核心应用、RawIngress 回放及快照加尾部重放收敛，恢复不重发 | 05 |
| [07 运行与跨所接线](issues/07-runtime-cross-venue-wiring.md) | 注册配置、账户路由、capability 和现有控制面/Owner 接线；核对策略同结算资产 USDC—USDC 合同，复用双 IOC 与 Maker–Taker；默认离线、既有 Venue 不回退 | 04、06 |
| [08 分批 Testnet 验收](issues/08-testnet-qualification.md) | 先双 IOC 后 Maker–Taker，覆盖永续—永续与现货—永续；记录 revision、真实资产身份、环境、请求/事实及清理。未获批准资产或缺市场条件的指定品种保持 pending | 07；在线写入须独立明确授权及可用市场 |

关键依赖：`01 -> {02,03}; 02 -> 04; {02,03} -> 05 -> 06; {04,06} -> 07 -> 08`。

02 中只有经 01 与当前源码证明的真实共享缺口才改变合同；任何持久语义变化必须按仓库版本约定处理。账户配置写入能力先核对现有控制合同，有必要时独立列清影响，不把任意 Venue API 透传塞入 Adapter。

## Frontier

- [01 协议与字段合同](issues/01-protocol-field-contract.md)：open，无前置阻塞，尚未认领。

## Decisions so far

- 2026-11-02：用户最终确认整体理解与八个切片，已发布 01–08 本地实施票并保持既定依赖；发布不表示实现完成、在线授权或资格通过。
- 2026-11-02：用户确定首期覆盖永续、现货，BTC、ETH 为验收目标。
- 2026-11-02：用户接受 Testnet 完整闭环作为第一阶段完成目标。
- 2026-11-02：业务目标为跨所交易，包含永续—永续和现货—永续组合。
- 2026-11-02 Q4：标准线性永续限定逐仓模式，USDT/USDC 共用模型类型但分别绑定真实资产及 Venue 规则；独立核算，不合并余额或互相抵押。见 [ADR 0022](../../docs/adr/0022-separate-margin-model-from-settlement-asset.md)。当前代码仍待完成共享合同适配。
- 2026-11-02 Q5：允许经配置明确批准的包装/桥接现货参与经济敞口配对，各自资产身份保留；BTC/ETH 的实际 token 和 Testnet 市场仍待查证。
- 2026-11-02 Q6：专用真实交易账户由 Ringwin 独占交易，可承载多个 Ringwin 策略；agent wallet 签名并显式绑定资金账户。外部订单/仓位变化进入既有对账和安全处理，不自动归属策略。
- 2026-11-02 Q7 澄清：每个跨所组合只配同一种报价/结算资产，即 USDT—USDT 或 USDC—USDC；不做 USDT—USDC 配对，也不新增稳定币兑换交易。永续以实际结算 Asset 判定，不能只看 symbol 的 USD 字样。无需为本期配对增加跨币种汇率比较逻辑；既有报告估值职责不变。
- 2026-11-02 Q8：首期同时覆盖双 IOC 和 Maker–Taker，先验收双 IOC，再验收 Maker–Taker，资格独立记录。
- 2026-11-02 Q9 澄清：账户模式、杠杆目标与操作流程归项目配置/控制面，准入与风险反应归核心；Adapter 只负责支持范围内的协议转换、执行已授权请求及返回账户配置事实。本次不决定必须手工预设，不让 Adapter 自主选择或修改账户模式/杠杆。具体配置写入请求是否需扩展共享合同尚待核对，不能假定已有任意 Venue API 透传接口。
- 2026-11-02 Q10：首期支持限价 GTC/IOC、Post-only（ALO）、永续 Reduce-only、撤单及订单/成交对账。改价沿用旧单撤销终态及 Fill 核实后新建；不支持原生 modify、触发单、TWAP、按报价金额下单或 Adapter 自行定价的市价单。
- 2026-11-02 Q11：允许先推进共享合同、Adapter 和可用市场验收；BTC/ETH 指定现货缺项保持 pending，待资产身份和市场条件确认。不得替换币种、因此关闭整个接入或自动转到主网测试。

## 已核对的接入约束

- 执行与公共行情分别实现 VenueAdapter / MarketFeedAdapter，全部事实经既有核心应用及持久恢复路径。
- 资金账户地址与 agent 签名身份分别绑定；查询/私有订阅使用资金账户，不能回退到 agent 地址。
- 当前 CredentialStore 的凭证表示绑定 api_key/secret_key/passphrase；agent 私钥需要真实凭证类型与秘密生命周期支持，不填占位字段伪装兼容。
- 参考文档的 l2Book 为无交易所源序号的有限深度快照；现有深度合同每侧最多 8 档，按范围截断且不外推流动性。捕获顺序与交易所连续性证据必须区分，属于共享合同核对项。
- IOC 零成交拒绝与部分成交后剩余量终结分别映射；ExecutionReport 不替代经济 Fill，终态后迟到的唯一真实 Fill 仍须应用。
- Unknown 保留原身份、风险占用并对账，不因换 nonce、重连或一次未找到而重发。历史覆盖不足保持未解决，不根据余额差或订单累计量伪造 Fill/费用。
- 用户资料中的恢复仅覆盖部分场景，不能代替部分成交、取消、Reduce-only、重启及历史截断的完整性验收。

## Not yet specified

以下是实施前的协议核实与部署实例输入，不应把尚无证据的实现细节视为已批准事实；不再重新询问已确认的业务范围。

- BTC/ETH 现货对应的实际 token、包装/桥接资产及 Testnet 可用性。
- 现有跨所策略规格限定 USDT，需扩展到同结算资产的 USDC—USDC 组合；不引入跨币种组合。
- agent signer 的凭证、nonce 及主备生命周期合同。
- 订单、行情、签名、nonce、限流、Unknown 与补回合同。
- 跨所验收对手 Venue、产品组合与资金配置。

## Testnet 只读元数据核查

2026-11-02 02:44:03–02:44:22（UTC+8），公开端点 `https://api.hyperliquid-testnet.xyz/info`，请求类型 `meta`、`spotMeta`、`tokenDetails`；未读取凭证或调用交易接口。以下为当次观察，不是持久不变的配置或在线交易资格。

- 标准永续 BTC/ETH 分别位于 `meta.universe[3]` / `[4]`；`collateralToken=0` 对应 USDC。
- USDC tokenId 为 `0xeb62eee3685fc4c43992febcd9e75443`。
- UETH/USDC 现货 pair `@1137`，tokens `[1242,0]`；UETH tokenId `0xe4371d8166f362d6578725f11e0a14f3`。仅确认 listing，名称和 tokenDetails 不足以证明包装/桥接经济身份。
- 未找到名称为 UBTC 的 token；名为 BTC 的 token69 为非 canonical，tokenId `0x286820da26c94f1e0ff1e436238f2384`，pair `@50`，fullName/evmContract 均为空。不能仅靠名字认作已批准的 BTC 资产。
- 未验证流动性、逐仓实际配置、下单/成交能力或对手 Venue 的同结算资产市场。缺失证据保持 pending，不用其他市场结果替代 BTC/ETH 指定范围。

补充请求依据：[API 环境](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)、[Spot 元数据](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/spot)。仅在用户资料缺少请求地址/格式时补查官方资料。

## Out of scope

- 当前未授予主网交易、资金划转或部署权限。
- 首期不支持全仓、统一/组合保证金、HIP-3/HIP-4 或 vault。
- 不支持手工交易或其他机器人并发使用同一真实交易账户。
- 不包含 USDT—USDC 跨币种组合或新增自动换币、跨链、资金划转能力。
- 不包含原生 modify、触发单、TWAP、按报价金额下单或 Adapter 自行定价的市价单。
