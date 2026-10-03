# 05：贯通高精度结算资产费用与原币账务

Type: task
Status: open
Assignee:
Blocked by: [04：贯通 AssetDefinition 激活与精度范围准入](04-activate-authoritative-asset-precision.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“贯通高精度结算资产费用与原币账务”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

配置精度下的结算资产费用、返佣、现金、posting 与风险计算使用一致单位，单笔和累计金额保持精确。

## Acceptance criteria

- [ ] 十二位测试配置中两组指定 USDT 费用分别精确记为 4198632165 与 4237238520 atoms；十笔 0.0000001 费用精确累计 0.000001 USDT。
- [ ] fee/rebate 独立原币 posting；不把正返佣舍零、零当缺失，不改写成交数量或 OMS 报告累计值。
- [ ] 消除本切片金额状态、posting、累计及资金限制的 i64 窄化；按已准入范围选既有宽整数，不无差别扩大身份与数量字段。
- [ ] 价格 ticks、数量 lots、tick 价值、数量尺度与合约乘数计算名义/结算金额时单位明确；扩大 USDT 精度不改变真实经济值。
- [ ] 风险预估和预留的显式保守舍入保留，但实际费用/余额禁止取整；确需 Venue 产品结算舍入时绑定规则版本与独立差分证据。
- [ ] 逐 Asset 内部双层闭合、重复 no-op、冲突和累计溢出均通过 Owner→TradingShard→账本→持久与重放验证；失败无局部经济提交。
- [ ] 如共享金额重定型无法逐切片落地，使用隔离集成分支承载关联修改并明确绿色验收点；不得在旧 schema 中写入新状态、不得创建并行权威账本或猜测迁移。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、02、03、04、07、08、09、23、24。
- Implementation Decisions：D2、D3、D6、D7。
- 验收矩阵：M01、M02、M04、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

