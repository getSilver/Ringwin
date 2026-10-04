# 03：让有界 Decimal 等价文本贯通规范事实

Type: task
Status: in_progress
Assignee: codex/asset-precision-accounting
Blocked by: [02：停止真实金额取整并持久关闭新增风险](02-fail-close-inexact-economic-facts.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S2

## Question

如何通过既有公开 interface 完成“让有界 Decimal 等价文本贯通规范事实”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

受支持输入长度内的长尾零、符号及全零形式产生同一数值和业务身份；真正越界仍经数值故障路径关闭交易。

## Acceptance criteria

- [ ] 明确十进制语法、输入长度、i128 系数、有界 scale 及缩放范围；格式验证之后、系数累积之前裁掉无意义小数尾零，不使用浮点或 BigInt。
- [ ] 1 加长小数尾零、正负零和合法前导零的等价表示不会产生假溢出；同一经济事实身份与有效内容一致，RawIngress 仍保留原文。
- [ ] 正负整数边界、费用绝对值不可表达、scale 超限、缩放幂及真实系数越界返回可区分失败；格式错与缺值不被规范化为零。
- [ ] 通用数值解析复用一个最小算法，覆盖三家 Adapter 使用的 Decimal；不引入 Venue 专用核心解析分支。
- [ ] Decimal.parse/exactAtoms 检查与原始 WS/REST→核心→重放样本同时验证；等价文本不削弱冲突检查与完整审计摘要。
- [ ] 身份或持久数值语义变化提升 schema；原失败保护持续生效。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：13、14、15、09。
- Implementation Decisions：D4。
- 验收矩阵：M08、M09、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

