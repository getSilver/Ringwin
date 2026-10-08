# 11：证明精度账务与故障状态的崩溃恢复

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [10：用独立 Venue 事实核对逐 Asset 经济账](10-reconcile-independent-venue-economics.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S4

## Question

如何通过既有公开 interface 完成“证明精度账务与故障状态的崩溃恢复”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

精确金额和未解决数值故障在 raw/规范事实/提交/快照各中断点都能恢复，不丢事实、不重复账、不重新发送。

## Acceptance criteria

- [x] 在 RawIngress 提交、report、Fill、失败事实、Owner 决策提交及 snapshot barrier 前后注入中断；沿既有逐事实提交模型恢复。
- [x] 断点恢复相同事实序列下 CanonicalStateDigest 一致，资产配置、宽金额、posting、唯一 Fill 证据、未处理游标与锁存状态完整。
- [x] 表驱动 report/Fill、WS/REST 合法排列只用 SemanticAuthorityDigest 比较经济收敛；审计 Trace 和 canonical ingress 顺序不能删减。
- [x] 队列满、ledger/证据容量满、存储失败及途中再崩溃均保持未完成来源并 fail-closed；replay 外发次数为零。
- [x] 刷新并核对 canonical/encoding/journal/state/registry 激活合同；旧、不匹配或损坏 schema 明确拒绝，原证据不删除，不双读双写或猜测迁移。
- [x] 所有先行票已各自闭合 codec/恢复，本票作全链故障证明，不以此票延期补做早期票的 schema 更新。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：08、09、11、18、19、20、21、22、25。
- Implementation Decisions：D3、D4、D5、D6、D7。
- 验收矩阵：M07、M09、M10、M11、M12、M13、M14、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。


2026-10-08：10已封存14a088a6；root认领11，Sol6.1 medium代理负责既有Windows file故障/重开切片，root负责实际Adapter排列及容量闭合。12并行；不执行完整main suite、在线调用或账户写入，验收保持待证。

2026-10-08：两名Sol6.1 medium代理达到额度上限，root接手，未改子代理模型。当前实际WS先于REST、report先于REST Fill、REST Fill先于WS report三种排列Debug通过2/2，ReleaseSafe连同旧native settlement合同9/9通过；逐排列自己的canonical恢复一致，跨排列只比SemanticAuthorityDigest，保留不同raw/Trace。统一ingestCommitted补ready fills-history白名单且不计bootstrap分页完成。文件native16种中断（raw append/commit、prefix0/1/2、Owner append/commit、snapshot seal/publish/成功、fault及再次重开）Debug已通过。实际unowned funding先耗尽16 SafetyGate，而非32 economic fact；不放大容量或改归属，保留这一真实上限验证。发现gate满会阻止原金额故障持久记录，latchEconomicFault现关闭既有trading_authorized并保留fault/原evidence，容量原因显式归类；定向Debug2/2通过并经Owner recover/snapshot核对。32fact/ledger及其他全链项仍待进一步核对，未封存。

2026-10-08封存：最新11/12联合定向Debug13/13、ReleaseSafe13/13通过，fmt/diff检查通过。现有公开队列满/decoder拒绝、第三Asset ledger满与真实16gate满保留来源；新增33个perpetual raw Fill验证前32个seen/canonical-fill-evidence和64个ledger完整，第33个capacity fault无部分经济提交，日志恢复及snapshot一致。该容量用例的native margin由明确可信规范前置事实提供；不把OKX USD margin视为原币，也不证明真实Venue杠杆准入。真实WS→REST duplicate、report→REST Fill、REST Fill→WS report排列保持相同SemanticAuthorityDigest而保留不同canonical/raw审计；每条自身恢复保持CanonicalStateDigest。既有4条规范排列/固定seed32场景通过；冲突的旧“全部状态不变”断言调整为经济账不变、持久fault留痕与RecoveryOnly，不放宽身份或幂等。

文件矩阵现18场景：在prefix report后恢复过程中再注入append/commit失败并再次重开，raw barrier/source digest保持；append重开仍需完整sweep，commit尾部保留未提交证据且拒绝Owner准入，无自动截断/重写。其余覆盖raw commit前后、report/Fill逐事实前缀、fault、Owner append/commit、snapshot seal/publish及成功发布。相同原始序列核对宽USDT12/BTC9、>i64金额、配置、posting、唯一Fill、锁存与审计digest；replay sends=0。有效校验和下旧state/registry/artifact/encoding header、payload corruption、旧canonical/encoding/journal被明确拒绝，原raw segment digest未改变。

本票未新增持久字段/编码，沿10的canonical/encoding10、journal30、state34、registry28；早期票schema不延期补做。已完成离线交付，独立两轴最终全变更审查及完整main suite待14，未宣称本票取得新的在线/生产资格。Sol6.1 medium代理额度限制后root完成剩余实现与核对。