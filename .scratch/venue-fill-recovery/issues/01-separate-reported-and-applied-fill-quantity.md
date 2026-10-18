# 分离 Venue 累计成交与已入账 Fill

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何让 OMS 保留 Venue 报告的累计成交事实，同时由经济投影独立判断唯一 Fill 是否可入账，使
report 与 Fill 的到达顺序既不触发误判，也不能绕过 overfill 和身份冲突保护？

## What to build

形成一条完整的成交应用路径：Venue 累计报告只推进订单生命周期，经济投影保存每个订单已实际应用
的唯一 Fill 总量，并在应用当前 Fill 前以订单原始数量校验上限。该状态随权威快照、重放和摘要恢复；
若改变冻结结构，则显式提升 schema 并拒绝旧状态。

## Acceptance criteria

- [ ] OMS 的累计成交字段只由 execution report 或 reconciliation 推进，不因应用 canonical Fill 再次累加。
- [ ] overfill 使用“已应用唯一 Fill 总量 + 当前 Fill 数量不超过订单原始数量”，全部算术 checked。
- [ ] filled report 后同笔 Fill、Fill 后 filled report、partial report 后多笔 Fill 均成功收敛到同一状态。
- [ ] 多笔 Fill 总和刚好等于订单量成功；任一新的唯一 Fill 导致超量时在提交经济变化前失败关闭。
- [ ] 重复 Fill 身份是 no-op；相同身份但 payload 不同在任何到达顺序下均失败关闭。
- [ ] 延迟、乱序、重复 report，以及 cancel/reconciliation 已含累计量后到达的 Fill 不会重复记账。
- [ ] 新的已应用 Fill 状态进入 snapshot、semantic replay 和 `CanonicalStateDigest`，live/replay 摘要一致。
- [ ] 若持久结构变化，schema/registry 版本同步提升，旧格式稳定失败关闭且不增加兼容猜测。
- [ ] Debug 与 ReleaseSafe 的最小回归均通过，并保留一条在修复前可复现线上失败的脱敏固定用例。

## Out of scope

- 改写 OKX 私有协议解析或 Demo runner 生命周期。
- 删除累计报告、overfill 或冲突身份保护。

## Answer

`economics.Projection` 现在随唯一 canonical Fill evidence 保存订单身份和已应用数量；
`TradingShard` 只以该订单的 checked applied total 加当前 Fill 校验 overfill，不再以 Venue
累计 report 作为经济入账量。OMS 仍只由 report/reconciliation 推进。

该持久状态进入 projection/state digest、snapshot 和 semantic replay；StateSchemaVersion 升至
16，SchemaRegistryId 升至 13，旧快照继续失败关闭。公共 `CanonicalEvent -> TradingShard`
回归覆盖 filled report 后 Fill、唯一 Fill 重放、冲突身份、overfill、snapshot 和 replay；Debug 与
ReleaseSafe 通过，格式及 diff 检查通过。
