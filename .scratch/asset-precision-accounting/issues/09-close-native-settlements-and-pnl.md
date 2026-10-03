# 09：贯通资金结算及成本、PnL 的精度合同

Type: task
Status: open
Assignee:
Blocked by: [07：让第三 Asset 费用与返佣形成原币闭环](07-account-for-third-asset-fees.md)、[08：精确接入原币余额与保证金观察](08-preserve-native-balances-and-margin.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“贯通资金结算及成本、PnL 的精度合同”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

在新资产单位下既有资金流、资金费和强制执行的经济事实保持精确，成本释放和 PnL 不重复改变现金。

## Acceptance criteria

- [ ] 覆盖已存在的资金流/OpeningBalance/PortfolioTransfer、FundingSettlement、强制执行费用/罚金及真实结算金额，不增加新产品或通用结算平台。
- [ ] 所有真实金额依激活单位精确转换；生成金额的 Venue 结算公式/舍入须有明确版本和差分验证，风险估算舍入不能冒充实际费用。
- [ ] 保留 AverageCost/OpenCost、部分平仓成本释放余数、完全平仓归零及反向成交合同；费用/返佣/资金费独立分类，RealizedPnL 不产生重复余额变化。
- [ ] 能精确表示但不能归属的真实金额才进入 SuspenseAccount 并关联 break；不能表示的金额保持来源未解决，不猜测 Treasury/Suspense 尾差。
- [ ] 基础/结算/第三资产与多笔累计边界均有固定整数验收，逐事务逐资产闭合，错误事务不局部提交。
- [ ] 既有结算与资产 ledger 恢复同一金额及身份，相关 codec、schema、snapshot/digest 在本票闭合。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、03、04、07、08、09、23、24、25。
- Implementation Decisions：D2、D3、D5、D6、D7。
- 验收矩阵：M05、M06、M09、M12、M13、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

