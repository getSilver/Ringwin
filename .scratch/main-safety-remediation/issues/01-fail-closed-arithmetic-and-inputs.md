# 01: 使极值算术与缺失输入失败关闭

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (can start immediately)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让所有影响名义价值、保证金、费用、强平距离和 OMS 数量的极值输入稳定失败，同时不把缺失的费用、盘口数量或不兼容产品模型猜成可交易值？

## What to build

让一个极值或信息不完整的 CanonicalEvent 从接入、风险评估、OMS 到日志形成单一失败关闭结果：不提交候选状态、不产生 OrderCommand、不释放 RiskReservation，并留下稳定、可重放的拒绝原因。

## Acceptance criteria

- [x] 数量、价格、费率、名义价值、buffer、distance、累计量、剩余量及 amend 数量的全部乘加除法使用 checked arithmetic，溢出返回稳定领域错误。
- [x] 最小/最大整数、接近边界的合法值及跨零数量均有 Debug 与 ReleaseSafe 测试；结果不依赖 trap 或未检查构建语义。
- [x] 缺失 fee、关键 L2 数量或不兼容 Product/ReservationModel 被明确拒绝或保留为 Unknown，不再补成 0、1 或其他产品。
- [x] 任一拒绝不改变 OMS、风险、账本、SafetyGate 或 CanonicalStateDigest；live 与 replay 得到相同拒绝事实。
- [x] 生产构建合同继续固定 ReleaseSafe，且验收能阻止未证明安全的 ReleaseFast 被用于生产资格。

## Out of scope

- 浮点计算、任意精度数学库或为极端但无业务意义的数值扩大 wire schema。

## Answer

已在风险、OMS 与分片权威入口统一使用 checked arithmetic 和显式缺失值拒绝；Debug/ReleaseSafe 极值及拒绝无副作用轨迹已通过。
