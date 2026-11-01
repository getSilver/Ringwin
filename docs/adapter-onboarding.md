# 新增交易所 Adapter 操作手册

本手册用于新增 Venue、扩展现有 Adapter 能力及审查接入边界。目标是让协议变化集中在
`src/adapters/<venue>/`，核心继续依赖 Venue 中立合同。它落实既有架构，不授予真实交易权限。

## 1. 开始前：确认范围与依据

1. 阅读 [GLOSSARY](../GLOSSARY.md)、[ADR 0001](adr/0001-separate-venue-execution-and-market-feed-seams.md)
   和[多交易所适配方案](多交易所适配方案.md)。旧方案中的路径、schema 和测试数量是历史信息；
   接口签名、实现能力和验收状态必须按当前源码核对。实现与 ADR 冲突时显式记录差异，不静默改变架构。
2. 检查工作区和受影响调用链，记录已有修改；不要覆盖其他任务的代码或迁移。
3. 按[本地 tracker 约定](agents/issue-tracker.md)，在对应 `.scratch/<module>/map.md`
   及 `issues/` 记录接入范围、依赖和验收证据；不默认同步 GitHub。
4. 明确产品、品种、环境、账户模式、订单类型、行情范围及不支持项。
   “支持该交易所”不能代替这些具体范围；仅接公共行情时不宣称执行能力。
5. 从官方 API 文档建立消息清单，记录来源链接、查询日期、版本及样本来源。
   现有 Adapter 可参考组织方式，但不能证明新 Venue 的协议语义。

完成条件：范围和不支持项可检查，每项计划能力都有协议依据，待确认事项明确保留为未支持。

## 2. 先列改动清单，再实现

按下表为每个拟改文件标注职责。新增 Adapter 通常只需要私有实现、测试及少量组装注册；
“零核心修改”不是掩盖真实领域缺口的理由。

| 改动位置 | 允许的职责 | 边界 |
|---|---|---|
| `src/adapters/<venue>/` | 认证、签名、REST/WS、codec、限流、分页、协议去重、bootstrap、重连与对账 | 不拥有权威订单、风险、账本或投资组合状态 |
| `src/runtime/`、现有可执行入口 | 创建 Adapter、注入 transport/凭证能力、绑定账户路由及行情订阅 | 只做组装；不复制核心或绕过 Gateway 建立下单捷径 |
| 现有配置/身份登记位置 | 注册 Venue、账户、产品、规则和能力证据 | 身份与规则显式绑定，不借用其他 Venue 的身份或默认单位 |
| `src/testing/`、实现内单元测试 | 私有协议测试、共享契约、故障与恢复验收 | 必须经过公开 seam；私有 helper 通过不代表集成完成 |
| `src/entry.zig`、`build.zig`、`tools/` | 注册独立测试入口、加入现有离线验收编排 | 不隐式联网、读取真实凭证或开启交易 |
| 字段矩阵、能力证据和本地 tracker | 声明支持范围、映射、限制和实测结果 | 离线、只读、Demo/Testnet、生产证据分别记录 |
| `src/model/`、`trading/`、`execution/`、`risk/`、`portfolio/`、`market/`、`persistence/`、`security/` 的共享合同 | 仅处理已确认的通用领域或安全能力缺口 | 走第 6 节，不将 Venue 特例塞入共享路径 |

生产依赖方向保持为：

```text
运行组装 -> 具体 Adapter -> 共享执行/行情合同、规范事件
核心状态机 / Gateway -> 共享合同
```

核心生产路径不得依赖具体 Adapter、SDK、Venue JSON 字段或错误码。测试代码引用具体实现
不等于生产依赖，审查时区分用途。策略只使用规范输入和意图，不按交易所协议改变下单路径。
不为接入建立动态插件、通用 REST/WS/auth 框架、第二套 runner/core 或重复的控制面。

完成条件：所有调用方、测试、fixture、配置、入口及文档影响已列出；共享模块改动有独立理由。

## 3. 先完成字段映射和能力声明

扩充[字段处置矩阵](venue_field_disposition_matrix.md)，再编写 decoder。目标消息的每个字段归入
Canonical、AdapterInternal、RawEvidence、Unsupported 或 NotApplicable，并注明：

- 目标规范事件、类型、单位、精度、舍入规则、缺失或未知枚举的处理。
- Venue、ExchangeAccount、Instrument、Asset、session、来源流、事实身份及原始证据的绑定。
- REST 与 WS 对同一事实的关联、重复与冲突处理；不得用到达时间伪造成交身份。
- 快照的完整范围、分页终止条件、游标和 bootstrap 屏障；局部更新不得冒充完整快照。

能力声明沿用 [CapabilityProfile](../src/execution/execution_gateway.zig) 及其当前配置激活路径。
声明必须与实际实现及证据一致：缺失能力默认拒绝，不用空值或成功响应假装支持。
能力刷新不是交易授权；遵循 [Instrument 授权边界](adr/0012-bind-observation-and-trading-state-to-instruments.md)。
资产和品种单位来自已激活定义；金额、价格和数量精确转换到规范整数单位，溢出或不可表示时拒绝。
不能硬编码其他 Venue 的精度、结算资产或保证金模型来“兼容”新产品。

完成条件：目标消息没有未分类字段，每项支持能力可追溯到映射、实现位置和预定测试。

## 4. 实现两个独立接缝

### 执行与私有账户事实

实现当前 [VenueAdapter](../src/execution/venue_adapter.zig)：`start`、`trySend`、`tryDrain`、`stop`。
请求类型以 [AdapterRequest](../src/model/canonical_event.zig) 为准，订单、订单对账和账户对账
复用同一实现路径。实例固定绑定 Venue、环境、ExchangeAccount 和 session。

- 所有发送走现有 ExecutionGateway；保留发送前授权、fencing、版本和期限复核。
  Adapter 不生成策略意图、不重新风控、不自行择所，也不改写权威订单归属。
- `trySend` 接受请求不等于交易所接受订单。请求结果与私有事实经 `tryDrain` 输出规范事件；
  区分明确未发送、已提交和 Unknown。Unknown 必须对账，不能直接重发。
- 如需特定 ClientOrderId 格式，使用现有 `prepare_client_order_id` 扩展点；它只做纯编码，
  由 Gateway 在发送前持久化结果。不得在 transport 中悄悄换号。
- REST/WS 原文先经 RawIngress 捕获，再解码输出事实；原始证据提交失败不得继续宣称成功。
  凭证、签名秘密及认证材料不得混入日志或 fixture，复用已有安全生命周期。
- 保持输入帧、队列、分页、批次及每轮处理预算有界；契约操作不隐藏阻塞或分配。
  背压不能丢事实；stop 未 drain 完成时失败关闭。
- 对账输出观察和恢复证据，不直接修改 OMS、余额、仓位或账本，也不直接解除安全锁存。
  原因解除与恢复交易权限遵循 [ADR 0021](adr/0021-preserve-account-safety-causes-through-recovery.md)。

`ExecutionReport` 与 `Fill` 必须分离：报告累计量属于 OMS 的交易所报告状态；经济累计量属于
唯一已应用规范成交，不能用报告累计量加新 Fill 判断重复入账或超额成交。
遵循 [ADR 0014](adr/0014-preserve-applied-fill-quantity-across-economic-archive.md)，包括归档后的累计量和重复证明。
相同事实重复必须幂等，内容矛盾必须显式失败；账户余额差不能伪造成交或费用修订。

### 公共行情

实现当前 [MarketFeedAdapter](../src/market/market_feed_adapter.zig)，独立于账户执行连接和凭证生命周期。
产品定义、行情、参考价格、资金费率及健康信息经规范事件进入已有市场投影。
协议 book、序列和重同步状态留在 Adapter 内；共享市场状态仍由核心拥有。

序列缺口、冲突、规则变化和超出覆盖范围必须撤销对应资格，不能靠后续 delta 猜测恢复。
深度范围和重同步遵循[深度合同](depth-snapshot-contract.md)与[重同步合同](depth-resynchronization-contract.md)；
没有可靠序列或完整快照时明确降低能力，不伪造连续性。不同 Venue 不必具有相同序列算法。

完成条件：两条路径只跨接缝输出规范事实；断连、背压、错误输入及停机有明确结果，
没有直写核心状态或旁路发送。

## 5. 最后接入运行组装

在已有启动路径创建具体实现，通过 `ExchangeAccountIdentity -> VenueAdapter` 路由及公共行情
订阅范围接入。生产路径保留现有 Owner、Gateway、DurableStore、snapshot/replay 的职责，
不能把测试用 Owner 或模拟 transport 当作生产闭环。

默认验证路径保持离线且不读取真实凭证。只读、Demo/Testnet 写入和生产必须分别获得相应权限；
存在凭证、能连接或 capability 已登记均不等于允许发送。凭证或环境切换创建新 session，
旧 session 的 Unknown 和未完成订单仍需闭合；replay/dry-run 不持有真实发送能力。

完成条件：使用者仅需选择已登记配置；无需修改策略、OMS 或账本即可使用已声明的通用能力。

## 6. 遇到共享合同缺口时

1. 写出无法表达的具体事实或行为，并给出官方语义和输入样本。
2. 先判断能否由 Adapter 内部翻译、已有规范事件或明确 Unsupported 解决。
3. 若必须新增通用概念，在本地 tracker 单列前置任务；读取相关 ADR，必要时补充 GLOSSARY/ADR。
   不把字段命名为交易所术语，不在核心添加 `if venue == ...` 分支解决协议差异。
4. 列明所有既有 Venue、模拟实现、调用方、codec、journal、快照、digest、fixture 与恢复校验影响。
   若改变持久语义，按现有版本合同处理兼容性；不得只改内存结构而复用旧格式身份。
5. 先完成共享合同和既有实现回归，再接新 Adapter。不得因新交易所暂时无法映射而放宽全局验证。

完成条件：通用变更独立可审查、可验证；每个既有实现明确支持或拒绝新语义，没有隐式降级。

## 7. 验证顺序与交付证据

| 层次 | 必须证明 |
|---|---|
| 协议测试 | 官方样本、缺字段、未知枚举、精度/溢出、认证失败、限流、分页、重复及冲突 |
| 共享契约 | 新实现实际调用 [venue_adapter_contract](../src/testing/contracts/venue_adapter_contract.zig) 的适用检查及 MarketFeedAdapter 的共享检查；覆盖生命周期、容量、背压和停机 |
| 核心公开入口 | Adapter 输出经 Owner 的 `applyAdapterBatch`、`TradingShard.apply(CanonicalEvent)` 应用；report→fill 与 fill→report、重复与冲突均验证最终订单和经济状态 |
| 持久化与恢复 | RawIngress 回放、规范日志、快照加尾部重放及恢复屏障；故障前后 CanonicalStateDigest 收敛，且重放零发送 |
| 隔离 | 某账户/行情源断连或过载不阻塞其他账户；Unknown、旧 session、错误账户及权限失效不能发送 |
| 既有 Venue 回归 | 新能力没有改变现有 Adapter 的事件语义、路由、经济状态和恢复结果 |
| 在线验收 | 单独记录只读与显式授权 Demo/Testnet 的真实请求、私有事实、对账和清理；未运行项保持未取得资格 |

按范围复用 [fill recovery 验收](../src/testing/acceptance/venues/venue_fill_recovery_acceptance.zig)
和 [multi-venue 验收](../src/testing/acceptance/venues/multi_venue_testnet_acceptance.zig)。
不能只运行通用测试文件，却没有让新实现参加共享检查。

独立 Zig 测试先在 `src/entry.zig` 注册，使用已有包装器保持 `src/` 为模块根目录。例如：

```powershell
python tools/zig-entry.py test src/testing/contracts/venue_adapter_contract.zig -O ReleaseSafe
zig build test
zig build core-wave
```

第一条仅验证已接入的共享契约，不代表新 Adapter 已覆盖。新实现还须运行自身注册入口的
Debug/ReleaseSafe 测试，并加入现有离线编排；不能通过移除旧 Venue 或吞掉失败让整波通过。
在线命令必须由该 Venue 的验收入口和明确授权决定，不能套用其他 Venue 的 Demo 开关。

记录源码 revision、相关未提交改动、配置/fixture 身份、实际命令、环境、结果和未完成项。
不把固定测试数量、旧 tracker 的 closed 状态或离线结果写成当前在线资格；生产与平台资格独立。

## 8. 合并前检查

- [ ] 改动清单符合第 2 节；每个共享模块改动都能指向第 6 节的通用理由和证据。
- [ ] 核心生产路径没有新增具体 Adapter/SDK import、协议字段或按 Venue 特判的行为。
- [ ] 无旁路下单、直写权威状态、隐式交易授权或新增控制面。
- [ ] 字段矩阵、能力范围、错误处理、单位和不支持项与实现一致。
- [ ] 新 Adapter 实际参加共享契约，核心应用及持久恢复测试均有当次结果。
- [ ] 既有实现回归通过；未完成在线或生产验收明确保留为未取得资格。
- [ ] 默认入口离线，不加载真实凭证；文档、配置与构建入口同步更新。

这份清单是审查要求，不是已经存在的自动边界检查器。任何缺项须保留为未完成并写明原因；
不能仅凭手册存在宣称新实现已符合边界。
