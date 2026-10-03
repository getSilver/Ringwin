# 06：精确记录基础资产费用并分离 atoms 与 lots

Type: task
Status: open
Assignee:
Blocked by: [05：贯通高精度结算资产费用与原币账务](05-close-settlement-asset-precision.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“精确记录基础资产费用并分离 atoms 与 lots”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

BTC 等基础资产扣费和返佣按真实资产单位更新余额，成交数量保持订单 lots；净资产的交易步长以下余额完整保留。

## Acceptance criteria

- [ ] 九位 BTC 测试配置下 0.000000001 费用精确记为一 atom；旧八位配置失败关闭。
- [ ] 基础资产费/返佣独立资产 posting，与真实成交 lots 区分；不得把 fee atoms 或绝对资产余额直接转换为 lots。
- [ ] 覆盖非单位 lot/tick、不同资产原子精度、净买入/卖出及小于交易 lot 的残余资产；余额与订单成交数量均精确。
- [ ] 保持原 VirtualPortfolio 归属、双层资产数量守恒、AverageCost/OpenCost 既定合同，手续费不被塞入成本或改造成 overfill 依据。
- [ ] 同笔重复、冲突与 checked arithmetic 极值通过原始事实→核心→持久→恢复验证；新结构/单位更新相应 schema 和 digest。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：02、03、04、07、08、23、24。
- Implementation Decisions：D3、D6、D7。
- 验收矩阵：M03、M05、M06、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

