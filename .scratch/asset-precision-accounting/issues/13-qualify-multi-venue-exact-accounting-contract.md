# 13：闭合多 Venue 精确账务公开接缝合同

Type: task
Status: open
Assignee:
Blocked by: [11：证明精度账务与故障状态的崩溃恢复](11-prove-precision-crash-and-replay-invariants.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S5

## Question

如何通过既有公开 interface 完成“闭合多 Venue 精确账务公开接缝合同”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

OKX、Binance、Bybit 和 SimulatedVenue 经各自真实 Adapter 的公开路径遵守同一精度、费用、故障与恢复合同。

## Acceptance criteria

- [ ] 复用共享合同及各 Venue 的原始 WS/REST fixture，经 ingest/tryDrain→Owner→TradingShard→DurableStore→snapshot/replay 验证；不得只测共享 helper 或借 SimulatedVenue 替代真实 Adapter。
- [ ] 三家 Adapter 均使用同一激活资产精度，无私有精度常量遗留、Venue 专用核心分支、第二 runner 或通用插件。
- [ ] Venue 单笔/累计 fee/rebate、符号和币种按其能力合同翻译；字段语义或粒度无法证明时拒绝，核心不接私有字段。
- [ ] 逐 Venue 覆盖精确成功、微费用/返佣、base/quote/第三资产、非单位 lot/tick、未知资产、长尾零和真实溢出。
- [ ] 同一共享矩阵覆盖无 pending 故障、队列/存储失败、幂等、冲突、合法排列、独立对账及重启锁存，replay 无发送。
- [ ] 每个期望值为独立固定整数/尺度；资产未估值明确不完整，OMS cumulative 和唯一应用 Fill 数量保持分工。
- [ ] 矩阵只产生离线证据，不关闭现有在线/生产资格票，不执行账户交易或清理。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、02、03、04、05、06、07、08、09、10、11、12、13、14、15、16、17、18、19、20、21、22、23、24、25、27。
- Implementation Decisions：D1、D2、D3、D4、D5、D6、D7。
- 验收矩阵：M01、M02、M03、M04、M05、M06、M07、M08、M09、M10、M11、M12、M13、M14、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

