# 14：封存完整验收、覆盖矩阵与发布资格要求

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [12：只读审计历史取整差额并保留更正边界](12-audit-historical-quantized-fees-readonly.md)、[13：闭合多 Venue 精确账务公开接缝合同](13-qualify-multi-venue-exact-accounting-contract.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S5

## Question

如何通过既有公开 interface 完成“封存完整验收、覆盖矩阵与发布资格要求”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

形成可复现、逐项对应 Spec 的实现证据，明确受支持范围及新源码版本仍需哪些在线资格。

## Acceptance criteria

- [x] 将 Spec 的 28 个 User Stories、全部 Implementation Decisions、16 个验收场景和六项 Done when 逐项关联任务及实际证据；未通过/未运行项保持未完成。
- [x] 运行匹配改动范围的 Debug、ReleaseSafe 根合同、定向 codec/状态检查及 Linux 离线编译；必要时复用现有假 transport/进程链验证所有权，禁止伪造测试数量。
- [x] 证据绑定精确源码 revision/源码树、AssetDefinition 配置来源及内容哈希、各 schema、barrier、CanonicalStateDigest、SemanticAuthorityDigest 适用范围及 no-send 计数。
- [x] 封存数字语法、最大输入长度、支持精度与金额/累计/中间值范围；十二位 USDT/九位 BTC 仍是测试配置，生产值必须有来源与准入证明。
- [x] 清楚记录既有原型舍入及历史在线证据不能满足新精确账务合同；新源码的线上资格明确 not_run，禁止继承旧 Windows/Linux/ProductionQualified 资格。
- [x] 提供后续发布/重新资格的现有路径、必要前置证据及线上授权范围要求；不部署部分阶段，不交易、不清理、不改旧经济记录。
- [x] 更新本模块路线/Frontier 和实现证据；本票不修改或关闭父 Spec，若父项生命周期需更新由用户或独立流程处理；不同步 GitHub。
- [x] 不实现 Spec 明确排除的 BigInt/余数账本、在线精度重缩放、跨 schema 猜测迁移、新 Venue/产品或第二控制面。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：14、22、25、26、27、28。
- Implementation Decisions：D1、D2、D3、D4、D5、D6、D7、D8。
- 验收矩阵：M01、M02、M03、M04、M05、M06、M07、M08、M09、M10、M11、M12、M13、M14、M15、M16。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。


2026-10-08：13已提交b140fa30；14执行完整离线闭合。首轮根合同Debug/ReleaseSafe各421项，418通过、3失败，结果不作为通过证据；三处陈旧fixture已修正（合法当前cancel revision、Simulated资产激活、Binance当前unknown asset错误），最终定向两模式各4/4。全分支Standards审阅无发现；Spec发现OKX所有权跳过前缺原币校验，公开回归先红MissingEconomicFault、修复后两模式各5/5，提交5cd8c13b；继续闭合审阅发现的单笔/余额上限分工，在三家适配器跳过未归属execution前检查fee/rebate/PnL单笔范围，定向两模式各4/4。误改的既有Suspense fixture已恢复原100上限，其定向2/2通过。最终源码revision/完整套件/Linux及实际Windows假transport进程链仍待封存；所有验收checkbox保持未完成直到实际证据齐全。

coverage-evidence.md草稿已逐项列出28 Stories、D1-D8、M01-M16及六项Done，明确真实支持/拒绝scope。父Spec不改，历史更正和所有线上账户/交易/部署/清理未执行，资格not_run/false。
2026-10-08最终封存：执行源码521db8d13f1ba346b5815c412af060ace656b406（精确src Git树及逐文件SHA见../release-evidence.json），根合同Debug/ReleaseSafe各424/424且exit0；Linux x86_64-linux-gnu和Windows ReleaseSafe离线编译exit0。实际Windows假transport进程链exit0，OKX offline、role_ownership、durable_recovery passed且replay_send_capability=false；顶层windows_process_chain_verified/ offline仍blocked、read_only/demo_live not_run、production_qualification=false，不升级资格。实际offline fixture和four-shard入口exit0；四shard/三恢复路径的各barrier/digest以及shared摘要记录在report-14-four-shard.log。

coverage-evidence.md逐项关联28 Stories、D1-D8、M01-M16、六项Done与实际文件/合同场景；release-evidence.md封存语法/1024-byte/有界i128/scale与rescale0..38、资产及ledger/cumulative/intermediate范围、现有发布/重新资格路径。release-evidence.json绑定源码输入SHA8a5d0626a5db0300a4a7afe0e569cf081faa6b5b9de8701e5f198058c682d737、Zig版本、binary hashes、日志哈希、33实际私有Adapter case的activated registry SHA/decision raw barriers/CanonicalStateDigest/SemanticAuthorityDigest/no-send=0，及canonical/encoding10、journal30、state34、registry28、acceptance13。生产Asset精度/来源仍需另行资格，十二位USDT/九位BTC及BNB测试配置不能当作生产结论。

code-review双轴完整分支e8488457..b140fa30与最终增量：Standards无剩余发现；Spec P1（OKX unowned terminal monetary skip）和P2（单笔范围绕过）已修复并回归；当前424/424全套验证最终源码，未放宽OMS/资产范围或SafetyGate。审阅子代理均为Sol6.1中度。历史审计actual缺源保持unverifiable，未改旧记录或旧资格。

所有交付链接：[覆盖索引](../coverage-evidence.md)、[封存说明](../release-evidence.md)、[精确manifest](../release-evidence.json)。本票完成本地实施/离线验收，父Spec01原文及生命周期保持不变；不关闭既有在线、Linux或生产资格票，没有账户调用、订单、部署、清理、历史更正或GitHub同步。