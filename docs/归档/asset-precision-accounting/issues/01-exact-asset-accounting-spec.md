# 权威资产精度与精确经济账务优化落实 Spec

Type: spec
Status: open
Assignee:
Blocked by:
Parent: [落实权威资产精度与精确经济账务](../map.md)
Label: ready-for-agent

## Question

如何按已接受的定点、原币账务和恢复合同，消除 OKX 真实费用取整偏差，落实受支持 Asset 的权威精度，并明确 Decimal 数值范围与无法精确表示事实的处理规则？

## Problem Statement

SystemOwner 需要确认策略与真实账户记录的是 Venue 实际扣收或返还的金额，而不是本地为了保守风控构造的估算值。

当前 OKX 把 BTC 固定为八位、USDT 固定为六位；无法精确转换的金额先向下取整，再被当作规范费用、返佣或余额事实。负费用的绝对值被放大，正返佣可能被舍去。双层账本镜像同一取整结果，内部闭合无法证明与 Venue 金额一致。原文保存在 RawIngress，但没有相应费用余数账务。

Decimal 以 i128 系数及 u8 小数位数表示。实际越界会报错；OKX 在累积系数后才删除小数尾零，导致数值可表达、文本尾零较长的输入也会溢出。重缩放与账本内更窄的整数状态还有独立范围限制。

这些问题阻止系统按正式多 Venue 方案宣称精确原币账务。既有模拟原型的微 USDT 保守舍入和历史在线样本不能替代该要求。

## Solution

采用有限范围内的精确定点金额：每个受支持 Asset 有权威来源可追溯、版本化生效的原子精度及金额范围。Venue 真实金额只允许精确转换；未知资产、非零转换余数、范围溢出或精度冲突均保留原始证据，锁存受影响账户的新增风险权限，并维持未解决对账状态。

第一版不创建低于资产原子单位的余数账本。配置足够精度且通过范围准入的资产才能交易；遇到更细真实费用时停止准入并保留事实，不虚构一个最小单位、不忽略成交、不宣称恢复完成。若以后必须接纳这些金额，应另立明确的余数归属、累计、结算与更正合同。

费用、返佣、资金流与余额继续由同一核心和不可变账本负责。风险预估与订单规格化仍按各自显式政策执行保守舍入，不能改变实际成交费用。

## User Stories

1. As a SystemOwner, I want actual Venue fees recorded exactly, so that the ledger reflects real deductions.
2. As a VirtualPortfolio owner, I want tiny fees preserved at the configured precision, so that many fills do not accumulate fabricated costs.
3. As a VirtualPortfolio owner, I want rebates recorded separately and exactly, so that income is neither discarded nor merged into a negative fee.
4. As an ExchangeAccount owner, I want fees retained in their original Asset, so that the system never silently converts them to USDT.
5. As a SystemOwner, I want configured third-Asset fees supported by the same ledger, so that accounting does not depend on a base/quote-only assumption.
6. As a report consumer, I want assets without a valid valuation marked unvalued, so that missing prices do not become zero-value income or cost.
7. As a SystemOwner, I want distinct fills to sum to their exact Venue amounts, so that per-fill conversion introduces no cumulative bias.
8. As a recovery operator, I want repeated fills to have no additional economic effect, so that replay and reconciliation cannot charge twice.
9. As a recovery operator, I want conflicting duplicate facts to fail closed, so that changed amounts cannot overwrite prior economics.
10. As a SystemOwner, I want Asset precision activated through validated configuration, so that adapters cannot choose or change authoritative units.
11. As an auditor, I want each amount's precision interpretation recoverable from recorded versions, so that historical replay does not use current process settings.
12. As a SystemOwner, I want unsupported Assets and precision conflicts rejected before trading, so that the account cannot accumulate unaccountable exposure.
13. As an adapter maintainer, I want bounded decimals normalized before range checks, so that harmless textual zero padding does not overflow an otherwise valid value.
14. As an adapter maintainer, I want explicit finite input and arithmetic limits, so that the system does not promise arbitrary-length decimal support.
15. As an operator, I want conversion failures to identify their cause and raw evidence, so that inexact values can be distinguished from overflow and malformed data.
16. As a SystemOwner, I want numeric failures to latch trading safety even without a pending reconciliation request, so that an incomplete account view cannot continue increasing risk.
17. As a recovery operator, I want cancellation and reconciliation paths to remain available when safe, so that stopping new risk does not strand uncertain orders.
18. As an auditor, I want unrepresentable completed trades retained as unresolved source facts, so that rejection cannot erase a real execution.
19. As a recovery operator, I want bounded-buffer and storage failures to retain or recover pending facts, so that failure reporting itself cannot lose economics.
20. As a recovery operator, I want crash recovery to reconstruct the same amounts and safety state, so that restarting does not clear an unresolved numeric failure.
21. As a SystemOwner, I want replay to have no send capability, so that restoring evidence never repeats external orders.
22. As a release operator, I want incompatible historical schemas to fail closed, so that old integers are not silently interpreted using a new precision.
23. As a strategy owner, I want asset atoms, traded lots and price ticks converted explicitly, so that increasing precision does not change economic quantity or notional.
24. As a strategy owner, I want costs and PnL to retain their established rules, so that fee precision fixes do not introduce duplicate cash movements or hidden cost changes.
25. As an auditor, I want internal closure and independent Venue reconciliation both checked, so that mirrored errors cannot pass acceptance.
26. As a SystemOwner, I want historical accounting discrepancies reported without rewriting immutable records, so that any correction remains reviewable and traceable.
27. As a release operator, I want multi-Venue acceptance tied to an exact source and configuration identity, so that local evidence is not mistaken for online qualification.
28. As a SystemOwner, I want the plan separated from trading authorization, so that publishing a Spec does not authorize orders, cleanup or deployment.

## Implementation Decisions

### 1. 所有权与最小实现

- VenueAdapter 继续拥有私有文本、字段粒度、币种和费用正负号到 CanonicalEvent 的翻译；TradingShard 拥有经济归属、账本及安全状态。
- 复用当前数值值类型、规则配置、生效事件、Owner 提交和 DurableStore；不得新建通用插件、第二套账本或 runner 侧数值翻译。
- 费用和返佣须来自单笔成交事实；订单累计 fee/rebate 不能直接当作单笔金额。WS 与 REST 来源粒度不同，必须按 Venue 能力合同校验，无法证明时失败关闭。
- 明确零金额与缺失金额；非零金额必须有经激活的 Asset 身份与精度。不得凭报价资产补猜缺失费用币种。

### 2. 真实金额与保守估算

- 实际 TradingFee、TradingRebate、资金流、余额观察和原币保证金金额使用精确转换，不捕获 InexactDecimal 后 floor/ceil。
- 风控预估、费用缓冲、预留和订单规格化按明确版本化政策舍入；它们不能被写成 Venue 已确认的费用或余额。
- 根据产品公式推导的结算金额如有 Venue 明确舍入规则，须绑定该规则版本并做差分验收；不能把统一向上取整套到所有真实经济路径。
- USD 等估值字段与 USDT 原币金额区分语义，精度相同也不能默认等值换币。

### 3. 权威资产精度及范围

- 落实正式方案中的 AssetDefinition：记录 AssetIdentity、原子精度、配置版本、生效屏障、来源证据及允许范围，按既有配置发布路径激活。
- AssetDefinition 属于权威配置，不由 Adapter 自动观察值、链上 decimals、提现精度或 Instrument lot 推导。
- 每个原币金额须能从所属激活配置或明确版本引用确定单位；历史解码与重放不读取进程当前默认精度。
- 首版同一账本历史中的 Asset 原子精度保持不变；拒绝在线重缩放既有整数状态。精度升级需要独立、明确的状态兼容与切换计划，不能重用旧 schema 解释旧金额。
- 不在本 Spec 预设生产 USDT/BTC 的正确精度。先依据 Venue 经济字段证据和允许业务范围选择，再证明全部算术可表达。
- 公共金额保留明确的 i128 合同；逐一检查投影、posting、余额和累计算术中的 i64 窄化。金额状态需要更宽范围时改用既有宽整数，不一律扩大订单数量和所有标识字段。
- 准入覆盖单笔值、允许余额、唯一成交累计、乘法中间值、原子重缩放及 ledger 容量；运行时仍做 checked arithmetic。扩大小数精度不等于扩大可支持经济范围。

### 4. 有界 Decimal

- 保持普通十进制文本、明确输入长度上限、i128 系数和有界 scale；不承诺任意长度输入，也不引入 BigInt 或浮点。
- 在已校验文本格式及长度的前提下，先处理符号、无意义前导零和小数尾零，再对规范化结果做系数、scale 与重缩放范围检查。
- 有界字符串内数值等价的尾零形式得到相同数值及业务身份；RawIngress 仍保留原始文本，审计摘要不因规范化而被削弱。
- 全零、负零、正负整数边界、超长小数及缩放幂溢出均有明确结果。解析、正费用绝对值转换和账本范围检查各自负责自己的限制。
- InexactDecimal、DecimalOverflow、格式错误、未知 Asset、精度版本冲突及容量不足使用可区分的规范原因；不只留一行诊断输出或归并为通用 invalid_field。

### 5. 不可表达事实、余数及恢复

- 非零转换余数不得丢弃、借给下一笔 Fill 或伪记为一个最小单位。本版对它保留 RawIngress 审计引用并登记未解决的数值失败/对账状态。
- 复用能表达该故障的现有健康及对账事实；若现有结果仅适用于已发起请求，则增加最小的账户范围规范失败事实，携带来源、Asset/精度版本和原因，不伪造 reconciliation request 或经济金额。
- Decoder 拒绝、Adapter 转换失败和核心窄化失败都必须关闭新增风险；尤其覆盖正常 ready 模式下没有 pending reconciliation 的路径。
- 故障状态经同一 Owner/日志路径提交并进入快照；重启保持锁存，不因空 drain、内存标志重置或成功重连自行恢复 TradingAuthorization。
- 输出队列不足不得消费或标记完成故障来源；无法持久提交时立即本地关闭发送资格，由 durable ingress 恢复未完成事实。不得用无输出的成功 drain 掩盖失败。
- 未处理的真实 Fill 不计入已应用 Fill 集合，不释放 Unknown 或风险占用，不允许宣称经济对账完成；恢复后经证据确定性补记，绝不自动重发订单。
- 在安全合同允许的前提下保留撤单、对账与恢复能力。Reduce-only 只有在相关数量和权限可证明可信时才允许，不能绕过数值失败。
- SuspenseAccount 只记录已精确表示且无法可靠归属的真实金额；不能把无法表示的费用余数猜成 Suspense 金额。已知订单费用归属仍属于原 VirtualPortfolio，不能照搬 FundingAllocation 的 Treasury 尾差规则。

### 6. 原币账本与单位转换

- 费用、返佣、资产余额和 posting 以 Asset 及其固定原子单位表达，支持已配置的 base、quote 及第三费用 Asset；沿既有有界配置实现，不使用 Venue 或币种特判。
- 双层账本逐 Asset 闭合，唯一源事实与账务类型保持幂等。返佣独立分类；不得隐式换成 ReportingAsset 或把未知估值当作零。
- InstrumentQuantity 保持真实成交 lots；费用 atoms 和净资产余额不能直接当作 lots。明确 lot、tick、合约乘数与 Asset 原子精度的转换，净资产余额允许保留小于交易 lot 的真实数量。
- 接入费用精度不得改写成交数量来满足 overfill 校验；OMS cumulative_quantity 仍是 Venue 报告值，overfill 仍以唯一已应用 Fill 数量检查。
- 保留既有 AverageCost/OpenCost、成本释放余数与 PnL 合同；费用独立 posting，不因单位调整混入成本或重复产生余额变化。
- 对账不仅比较两层内部镜像，还比较独立 Venue snapshot/bill/fill 证据；来源时点、范围与游标必须匹配，差异显式形成 ReconciliationBreak，不覆盖本地账。

### 7. Schema、历史事实及资格

- 新配置、宽度、单位及故障状态的语义变化须协调提升相应 canonical codec、journal、state 和 registry 版本；实施时核对实际基线，不沿用旧 ADR 的版本数字。
- 每个可运行阶段如已改变持久语义，立即使用对应新版本；不得为等待最终发布把新状态写入旧 schema。阶段版本发布遵循现有 schema 激活合同。
- 快照和日志包含精度解释、原币账务、唯一 Fill 证据及未解决数值故障；旧状态按现有合同失败关闭，不引入猜测迁移或双读双写。
- CanonicalStateDigest 继续证明同一屏障的完整审计与恢复身份；合法到达排列仅用 SemanticAuthorityDigest 比较业务收敛，不要求不同排列的审计摘要相同。
- 对历史有损账先做只读源事实审计，报告真实值、原已记值、差额、Asset、规则版本和源事务身份。缺失原文不得推测补算，也不能因旧 schema 拒绝而删除历史证据。
- 历史更正需独立实施授权，通过引用原事务的冲正/更正追加，不覆盖旧 Fill 或 posting；本版不实现跨 schema 经济状态迁移。
- S1 仅完成安全止损，不能单独宣称恢复交易或正式多币种支持。完整实现及资格验收前，不部署部分修复到活动账户。
- 旧在线资格只属于旧执行源码；新版本按既有合同重新取证，本计划不改变任何历史报告或授予新的在线资格。

### 8. 优化落实顺序

| 阶段 | 阻塞 | 可交付结果 | 阶段验收 |
| --- | --- | --- | --- |
| S1 停止有损金额 | 无 | 删除真实金额转换的舍入兜底，贯通无 pending 场景的规范故障、Gateway 限制及 durable 恢复 | 六位 USDT 下不可表达费用不产生虚假 posting；故障立即阻止新增风险，原文及未完成状态可恢复；精确旧样本仍通过 |
| S2 精度与 Decimal | S1 | 配置 AssetDefinition、生效规则、边界准入及规范化解析，替换三家 Adapter 的私有精度常量 | 经测试配置可精确表示十二位 USDT/九位 BTC 示例；未知资产、缺版本、范围及精度变更均失败关闭；长尾零在输入上限内不造成假溢出 |
| S3 原币经济闭环 | S2 | 修复宽度窄化、atoms/lots/ticks 换算、第三资产费用和独立 Venue 对账 | 多笔微费用/返佣精确累计；非单位 lot 与不同 Asset 精度均正确；每层逐 Asset 闭合且匹配独立来源 |
| S4 持久与历史边界 | S3 | 完整 codec/快照/digest、失败恢复和历史只读审计流程 | 各崩溃点恢复相同经济金额与故障状态；旧 schema 拒绝、原事实保留；replay 外发次数为零 |
| S5 多 Venue 与发布 | S4 | 共享合同矩阵、证据清单及资格边界 | OKX/Binance/Bybit/SimulatedVenue 复用同一核心通过离线成功/失败路径；源码、配置、schema、barrier、digest 及 no-send 证据齐全 |

阶段顺序为 S1 → S2 → S3 → S4 → S5。该表是落实计划，不表示已有实现、测试通过或独立任务票已发布。

## Testing Decisions

- 用户已确认最高层验收接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 成功与故障都走调用方实际使用的 interface。测试外部可观察金额、归属、posting、权限、未处理状态和恢复结果，不直接访问取整 helper 或通过写私有状态构造成功。
- Decimal.parse/exactAtoms 仅补有界公共值类型的格式、范围与精确转换检查，不另设测试专用 interface。
- 复用当前成交恢复 raw fixture、表驱动排列、冲突/重复证据、逐事实提交和崩溃注入。保留原批次提交模型，不能为通过测试贸然改成整批原子事务。
- 精确期望值用固定整数及明确尺度，不能调用被测转换函数生成 expected；逐笔与累计结果均须断言。

### 必须覆盖的验收矩阵

| 场景 | 核心断言 |
| --- | --- |
| USDT 费用 -0.004198632165、-0.00423723852 | 不满足旧六位精度时失败关闭；十二位测试配置下分别精确扣收 4198632165、4237238520 atoms，不采用 floor/ceil |
| 十笔 USDT 费用 -0.0000001 | 七位或更细测试配置下精确累计 0.000001 USDT；旧六位精度失败关闭，不记成 0.000010 |
| BTC 费用 -0.000000001 | 九位测试配置下精确记为一 atom；旧八位精度不伪记成一 atom |
| 正返佣、显式 rebate、零与缺失 | 正金额精确入 TradingRebate；明确零不等于缺失；粒度、币种或字段冲突不能静默补猜 |
| base/quote/第三 Asset 费用 | 原币归属和 posting 正确；未知 Asset 停止准入；第三资产未估值不被写成零 |
| Asset 原子精度不同于 lot/tick | 成交 lots、资产余额、费用、名义价值和净资产正确；小于交易 lot 的真实余额不会丢失 |
| 精度配置激活、同版本冲突与重放 | 未激活/缺版本不能交易；相同配置幂等，冲突失败；新进程默认值不改变旧金额解释 |
| 长尾零、全零、符号与非法文本 | 输入长度上限内等价数值一致；超限、非法格式和真实系数/scale 越界明确拒绝 |
| i128 及窄整数边界、缩放幂与累计溢出 | 成功和失败均在公开合同内；无 trap、饱和、截断或局部经济提交 |
| 无 pending reconciliation 的 ready 模式转换失败 | 规范失败事实可观察、持久 SafetyGate 锁存、Gateway 无新增风险发送；空 drain 不等于健康 |
| 输出容量不足、RawIngress/决策提交失败 | 不消费未发布故障事实；本地 fail-closed；重开存储后可恢复未完成来源，无重复账务 |
| report/Fill 的合法逆序、WS/REST 补证和重复 | OMS cumulative 保持报告语义；唯一 Fill 经济作用一次；最终 SemanticAuthorityDigest 一致，审计顺序保留 |
| 相同身份不同金额/币种/精度解释 | 冲突失败关闭，不覆盖原 posting；原事实和故障均可审计 |
| 成交前后、故障记录前后及快照屏障崩溃 | 同序恢复 CanonicalStateDigest 一致；金额及锁存状态保留；replay 无发送能力 |
| 独立 Venue 对账 | 来源范围和时点可证明；内部镜像一致但外部金额不同仍形成 ReconciliationBreak，不自动填补余额 |
| 历史取整样本 | 只读审计能关联源事实并报告差额；不改旧记录、不授予新版本资格 |

- 运行与改动范围匹配的 Debug、ReleaseSafe 根合同及定向检查；codec 和状态变更验证稳定编码、旧版本拒绝和 Linux 离线编译。复用已有验收入口，不预设固定测试数量或重复轮数。
- 文档链接和元数据通过不等于产品完成。所有实现证据绑定精确源码/配置身份，线上项目明确记录 not_run，后续授权在线时核对真实费用、最终账户状态和新增版本资格。

## Done when

- [ ] S1–S5 对应实现、验收和失败路径证据齐全，受支持数值范围明确且不存在真实金额静默取整。
- [ ] 资产精度与金额范围可追溯，三家真实 Adapter 不再拥有互相独立的币种精度常量。
- [ ] 费用、返佣、余额及 posting 按 Asset 精确表达，内部闭合和独立 Venue 对账均通过。
- [ ] 不可表达事实在无 pending、队列满、持久化故障及重启下均保留证据并锁存权限。
- [ ] 合法重复、冲突、乱序、快照及无外发重放满足既有权威合同。
- [ ] 历史取整账和旧资格的边界明确；未执行更正、线上写入或新版本资格不得标记为通过。

## Out of Scope

- 本次规划直接实施代码、部署、提交/推送代码、真实交易或自动清理。
- 任意长度 Decimal、BigInt、低于原子单位的通用余数账本及自动冲正。
- 在线重缩放已有资产账本、跨 schema 猜测迁移、双读双写和旧经济记录覆盖。
- 新 Venue、新交易产品、组合保证金、SOR、完整多币种估值平台或新的控制面工具。
- 放宽 overfill、幂等、来源粒度、账户隔离、对账容差、存储门槛或 SafetyGate 以绕过失败。
- 继承历史在线资格，或用离线结果关闭 Linux/生产资格票。

## Further Notes

- 2026-10-03：用户已确认 Testing Decisions 所列接缝；本 Spec 按本地 tracker 发布为 ready-for-agent，尚未实施。
- 当前源码基线：canonical schema/encoding 为 2；acceptance/journal/state/registry 为 13/22/25/19。以上仅为本次读取结果，实施前必须刷新。
- 当前闭合测试及历史在线报告包含向上取整后的 USDT 费用，不能作为本 Spec 的精确金额验收证据。
- 十二位 USDT、九位 BTC 只是明确的验收配置，不是生产精度结论；S2 必须提供正式 AssetDefinition 来源与范围证据。
- [正式多 Venue 数值要求](../../../docs/多交易所适配方案.md)、[账务规格](../../quant-trading-system/issues/15-accounting-and-pnl.md)、[事件兼容合同](../../quant-trading-system/issues/29-event-taxonomy-and-schema-compatibility.md) 是本 Spec 的设计依据。
- [既有成交恢复模块](../../venue-fill-recovery/map.md) 提供公开接缝及恢复先例；[Windows 验证模块](../../windows-process-chain-verification/map.md) 与 [生产资格模块](../../production-readiness/map.md) 继续限定各自的源码和环境资格。
- 当前源码定位参考：[OKX 金额转换](../../../src/okx_venue_adapter.zig)、[公共数值值类型](../../../src/canonical_event.zig)、[核心经济投影](../../../src/economics.zig)、[TradingShard](../../../src/trading_shard.zig)、[Owner](../../../src/demo_authority.zig)、[稳定 canonical codec](../../../src/canonical_event_codec.zig)。定位参考不固定 Implementation Decisions 的实现文件布局。
