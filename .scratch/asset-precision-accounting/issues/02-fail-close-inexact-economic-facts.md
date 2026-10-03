# 02：停止真实金额取整并持久关闭新增风险

Type: task
Status: open
Assignee:
Blocked by: 无（可立即开始）
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S1

## Question

如何通过既有公开 interface 完成“停止真实金额取整并持久关闭新增风险”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

OKX 已确认的费用、返佣和账户金额无法精确表达时，不再制造取整金额；从 ready 接入到核心安全栅栏、Gateway 和重启形成明确故障结果。

## Acceptance criteria

- [ ] 所有真实金额调用路径取消 floor/ceil 兜底；六位 USDT 下给定微费用、微返佣和九位 BTC 样本无虚假 posting，精确旧样本保持正确。
- [ ] 区分零、缺失、未知 Asset、格式、非零余数和溢出；保留 RawEvidenceRef。累计订单费用不能伪装成单笔费用；缺失币种不靠报价币猜补。
- [ ] 无 pending reconciliation 时也可经 tryDrain、Owner 与 TradingShard 获得账户范围规范故障，不制造 reconciliation request、不只打印错误或返回健康空批次。
- [ ] Decoder、Adapter 和核心拒绝均撤销新增风险；不重发、不过早记为已应用 Fill，不释放未决 Unknown/占用；允许安全合同证明的撤单与对账，Reduce-only 不绕过不可信数量。
- [ ] 输出不足保留未发布来源，持久化失败本地立即关闭发送；重启恢复未完成来源并保持锁存，重新连接不能自动恢复人工授权。
- [ ] 故障及精确成功样本沿公共 seam、DurableStore、codec、snapshot/replay 验证；新持久语义立即提升对应 schema，replay 无外发。
- [ ] 本票只证明安全止损，不授权部署部分修复或宣称正式多币种交易已可用。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、03、12、15、16、17、18、19、20、21、28。
- Implementation Decisions：D1、D2、D5、D7。
- 验收矩阵：M01、M02、M03、M04、M10、M11。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

