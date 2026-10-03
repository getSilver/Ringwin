# 11：证明精度账务与故障状态的崩溃恢复

Type: task
Status: open
Assignee:
Blocked by: [10：用独立 Venue 事实核对逐 Asset 经济账](10-reconcile-independent-venue-economics.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S4

## Question

如何通过既有公开 interface 完成“证明精度账务与故障状态的崩溃恢复”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

精确金额和未解决数值故障在 raw/规范事实/提交/快照各中断点都能恢复，不丢事实、不重复账、不重新发送。

## Acceptance criteria

- [ ] 在 RawIngress 提交、report、Fill、失败事实、Owner 决策提交及 snapshot barrier 前后注入中断；沿既有逐事实提交模型恢复。
- [ ] 断点恢复相同事实序列下 CanonicalStateDigest 一致，资产配置、宽金额、posting、唯一 Fill 证据、未处理游标与锁存状态完整。
- [ ] 表驱动 report/Fill、WS/REST 合法排列只用 SemanticAuthorityDigest 比较经济收敛；审计 Trace 和 canonical ingress 顺序不能删减。
- [ ] 队列满、ledger/证据容量满、存储失败及途中再崩溃均保持未完成来源并 fail-closed；replay 外发次数为零。
- [ ] 刷新并核对 canonical/encoding/journal/state/registry 激活合同；旧、不匹配或损坏 schema 明确拒绝，原证据不删除，不双读双写或猜测迁移。
- [ ] 所有先行票已各自闭合 codec/恢复，本票作全链故障证明，不以此票延期补做早期票的 schema 更新。

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

