# 09a 正现货 sub-lot 残余承接验证

基线 `33b12491`；独立分支 `codex/09a-residual`。Windows，Zig `0.17.0-dev.315+5b647b792`。记录于 2026-10-23；本分支不修改共享地图、issue、合同、GLOSSARY 或 ADR。

## 实现范围

仅允许 gross lots、open cost、margin 全部精确零，且 `0 < atoms < baseAtomsPerLot` 的正现货余量显式承接。已有 gross lots 但低于 Venue 最小订单或最小名义额的余额仍不能承接；当前 InstrumentRules 没有这些 Venue 阈值，不臆造它们。永续残仓、负资产、Unknown、未解决经济事实、对账或历史缺口继续阻止终结。

`CorePayload.spot_residual_rule` 配置按 Asset 的版本化规则：Asset definition version、单次原子数量上限、跨所有账户/周期累计上限和最大存续时间必须显式给定且为正。默认无规则，承接关闭；开发 fixture 的 1 atom、2 atoms、100ms 是边界测试参数，没有生产批准含义。最多 16 条 Asset 规则；规则身份冲突拒绝，新版本替换不改写旧残余的规则副本和截止时间。当前规则与已承接规则的配置事实均进入 checkpoint pin、摘要和恢复校验。

调用 `qualifyCycleResidualClosure(strategy, first_sequence, now_utc_ns)` 取得候选，再以 `cycle_closed` 核心输入提交。核心在实际提交时间重新资格核对，UTC 缺失或预备证明时间不匹配即拒绝；原精确零接口不会隐式承接。一次 Owner 事务同时保留双成员承接证据并释放双键。单个 Closure 两腿及以前已闭合周期一起计算累计上限。活动与终结身份合计仍最多 64 个，最多保留 128 条成员残余；没有终结身份回收或残余驱逐。

承接保留原周期、VirtualPortfolio、ExchangeAccount、Instrument、Asset、精确 atoms、Asset/Instrument 版本、lot 原子单位、规则副本及配置事实、经济摘要与原对账根。账本、费用和余额不改写，不转 Treasury，不重复估值；已有风险与估值投影继续计入这些资产。

共享 `qualifyOmsGroup` 在所有现货卖出库存检查中扣除同账户/组合/Asset 已承接数量，包括其他 Instrument 共享同一 Asset 的支用检查。闭合核对也扣除旧残余；Instrument 自身库存与账户可归属库存不一致、同 Asset 其他活动周期或其他非零品种库存造成歧义时拒绝承接。真实 Fill 的费用若消耗已保留库存，仍忠实入账、保留原残余记录，再锁存 OMS recovery-only；不能通过拒绝真实 Fill 隐藏经济事实。

旧残余达到原规则截止时间后，拒绝新承接及新增周期；余额不足或未闭合经济事实也阻止新增周期。规则更新不能延长旧残余期限。未承接可交易余额仍由原周期复用现有显式减仓权限。

**已承接 sub-lot 残余没有人工清理交易权限或解除保留接口。** 不自动归集、不补买、不把新周期权限当残余处置授权；到期后继续保留资产和风险，并阻止新增周期。后续清理须独立明确经济与权限合同。

## 实际验证

公共边界为现有夹具 `VenueAdapter.tryDrain → Owner.applyAdapterBatch → TradingShard.apply`，随后走 Owner/Store 与 snapshot/replay；不声称真实 Venue 私有协议或线上资格。

| 命令/证据 | 实际结果 |
|---|---|
| 首条 `--test-filter '09a explicit spot dust' -O Debug` | 红：缺少 `spot_residual_rule` 输入；实现后最初 2/2 绿 |
| `--test-filter 'real base fee consuming' -O Debug` | 红：真实 Fill 已记账，但 OMS recovery-only 未锁；见 `.scratch/build/09a-residual-fee-red.log/.exit` |
| 公共入口两个 filter，`-O Debug --stack 536870912` | 4/4，退出 0；`.scratch/build/09a-residual-debug-final.log/.exit`；此轮早于最后配置事实 pin 增强 |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/multi_account_authority_acceptance.zig --test-filter 'spot dust' --test-filter 'real base fee consuming' -O ReleaseSafe --stack 536870912` | **最终完整分支代码 4/4，退出 0**；`.scratch/build/09a-residual-release-final.log/.exit` |
| `zig test src/trading/cycle_occupancy.zig -O ReleaseSafe` | 2/2，退出 0；周期终结身份与规则容量、重复/版本冲突边界通过；`.scratch/build/09a-residual-module.exit` |
| 修改文件 `zig fmt --check`、`git diff --check` | 均退出 0 |

最终公共测试覆盖：未配置拒绝、规则内容/作用域/Asset version 校验、重复及版本冲突、两腿各 1 atom 时累计上限 1 拒绝/2 通过、提交时钟缺失/预备证明过时拒绝、重复承接无额外经济结果、卖出保护、新周期重用原品种与旧残余共存、新周期精确零闭合、规则更新不延期、到期拒绝新增、真实基础币费用吞残余后的忠实记账及锁存、所有唯一承接 append/commit 和 checkpoint publication 故障、文件关闭重开、摘要一致恢复，以及重新编码有效摘要但内容违反 lot/累计规则的 snapshot 拒绝。

早期 ReleaseSafe `.scratch/build/09a-residual-targeted.exit=1` 是旧失败，不能充当最终证据。该轮新增 snapshot 跨账户核对误入账户视图临时交换的递归校验；修为仅最外层执行跨账户核对，最新 ReleaseSafe 4/4 已覆盖修复及后续规则事实 pin。新增周期连测使用既有 checkpoint 维护 journal/trace 容量，没有放松核心容量门槛。

本分支 journal/state/registry 为 **45/49/43**，StateDigestV13 / SemanticAuthorityDigestV3；旧不兼容持久格式失败关闭，不提供迁移。费用分支独立修改格式，整合时主窗口统一最终版本与冻结轨迹摘要。

## 剩余边界

成功 FeeAdjustment 与已承接残余的交叉行为由费用分支整合后验证：旧周期费用涉及保留 Asset，无论增减都须保守锁存，不能把返还差额归新周期。本分支已实现实际库存不足锁存，不能替代该跨特性合同。共享 Asset 跨 Instrument 的扣除位于统一库存路径；独立新增的专门跨 Instrument 运行场景仍由整合回归补证。

未运行全量、Host 集成或实际 Venue；未更新固定轨迹摘要、未部署、未下单、未外部写入。生产阈值、已承接残余处置、连续运行容量、08/09b/09/10 与生产资格均未由本分支关闭。
