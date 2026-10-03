# 04：贯通 AssetDefinition 激活与精度范围准入

Type: task
Status: open
Assignee:
Blocked by: [03：让有界 Decimal 等价文本贯通规范事实](03-normalize-bounded-decimal-ingress.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S2

## Question

如何通过既有公开 interface 完成“贯通 AssetDefinition 激活与精度范围准入”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

同一份带来源依据的权威资产配置经生效事件到 Adapter、核心及恢复，决定整数单位和可用交易范围。

## Acceptance criteria

- [ ] AssetDefinition 明确身份、原子精度、版本、生效屏障、来源证据和允许范围；经现有配置发布与验证生效，不能由 Adapter、链上/提现小数位或 lot 推测。
- [ ] 三家 Adapter 及 SimulatedVenue 使用同一激活合同，不再维护互相独立的币种精度常量；未知 Asset、缺版本和未激活配置均停止准入。
- [ ] 相同配置幂等，同版本不同内容/版本倒退失败关闭；同一账本历史拒绝在线改变原子精度或重缩放旧余额。
- [ ] 配置与金额解释持久化并可恢复；新进程默认设置不改变历史单位；单位和能力尚不能被当前经济路径安全消费时维持 RecoveryOnly。
- [ ] 准入证明单笔、余额、累计、乘法中间值、原子重缩放和容量限制；运行时 checked arithmetic 继续存在。
- [ ] 十二位 USDT/九位 BTC 仅为测试配置；正式精度逐 Asset 提交 Venue 经济字段来源及范围证据，不能默认这些测试尺度就是生产正确值。
- [ ] 配置激活、拒绝和恢复均经 TradingShard 公共 interface、codec、日志及快照验证；当前版本基线刷新后协调提升 schema。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：10、11、12、14、22。
- Implementation Decisions：D3、D7。
- 验收矩阵：M07、M09。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

