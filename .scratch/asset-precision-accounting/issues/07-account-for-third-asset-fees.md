# 07：让第三 Asset 费用与返佣形成原币闭环

Type: task
Status: open
Assignee:
Blocked by: [06：精确记录基础资产费用并分离 atoms 与 lots](06-separate-base-atoms-from-trade-lots.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“让第三 Asset 费用与返佣形成原币闭环”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

已配置第三费用资产与 base/quote 使用同一账本，归属精确；未取得有效估值时明确显示不完整，而非零费用。

## Acceptance criteria

- [ ] 沿现有有界配置支持第三费用 Asset；不新增 Venue、交易产品、币种特判或第二账本。
- [ ] TradingFee/TradingRebate 按费用币种及原订单 VirtualPortfolio 分别记账；Portfolio/Exchange/Treasury/Suspense 逐 Asset 守恒。
- [ ] 未知/未激活 Asset、缺币种和尺度冲突失败关闭；仅有明确来源的零费用才能表示为零，不猜测币种。
- [ ] 缺少有效 ValuationRoute/价格时金额仍保留原币，估值明确为未估值/PnL 不完整；不隐式换 USDT 或将未知估值写零。
- [ ] 重复、冲突、容量和累计边界在同一公开 seam 验证；宽金额、资产 posting 与未估值状态按其权威/派生性质正确恢复，不弱化摘要。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：03、04、05、06、08、09、24。
- Implementation Decisions：D1、D3、D6、D7。
- 验收矩阵：M04、M05、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

