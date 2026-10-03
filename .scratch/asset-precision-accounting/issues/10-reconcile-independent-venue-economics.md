# 10：用独立 Venue 事实核对逐 Asset 经济账

Type: task
Status: open
Assignee:
Blocked by: [09：贯通资金结算及成本、PnL 的精度合同](09-close-native-settlements-and-pnl.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“用独立 Venue 事实核对逐 Asset 经济账”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

本地内部镜像一致但偏离真实金额时，独立 snapshot/bill/fill 核对仍能产生持久 ReconciliationBreak。

## Acceptance criteria

- [ ] 按匹配的账户/Asset、产品、时点、来源范围和游标核对独立 snapshot/bill/fill；不拿不同时间范围硬比金额。
- [ ] 构造 Portfolio/Exchange 两层相同但与 Venue 不同的金额，必须发现差异、记录稳定 break 并关闭新增风险。
- [ ] 匹配真实独立事实时逐 Asset 精确闭合；禁止宽松容差、覆盖余额、虚构划转或用新原子精度掩盖差额。
- [ ] WS/REST 费用粒度、source identity、重复补证和迟到事实保留权威语义；无法可靠证明粒度/身份时失败关闭。
- [ ] 未解决数值失败、未应用 Fill 和 Unknown 不允许被一次成功对账/重连顺带清除；恢复权限继续遵守人工授权。
- [ ] 固定精确值、差异、缺范围、冲突及重复沿公共接口及持久恢复验证，不用被测函数产生 expected。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：08、09、11、15、16、18、25。
- Implementation Decisions：D5、D6、D7。
- 验收矩阵：M07、M10、M12、M13、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

