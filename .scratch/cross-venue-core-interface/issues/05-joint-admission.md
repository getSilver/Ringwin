# 05：双账户共同准入与持久占用

Type: task
Status: open
Assignee:
Blocked by: [05a 多账户权威表示](05a-multi-account-authority.md)、[05b 共同准入与占用](05b-joint-admission-occupancy.md)
Parent: [模块地图](../map.md)

## Question

如何使完整双腿组仅在两腿和共享资源均合格时共同提交，并在崩溃后保留占用？

## What to build

依照已确认权威设计，将 Host 双腿候选贯通账户/品种/投资组合校验、资金和保证金检查、共享额度与占用、持久提交及命令生成。

## 完成条件

- [ ] 两成员的 ExchangeAccount、Instrument、VirtualPortfolio 与路由匹配；不支持的所有权组合明确拒绝。
- [ ] 任一腿不合格时不留下半组可发送命令或新预留；共同准入不声称 Venue 原子成交。
- [ ] A/B 与 A/C 竞争同账户品种时只能提交一个活动占用；不同品种共享资金不能超用。
- [ ] 在准入及持久提交前后注入故障，经公共恢复路径核对组身份、资金预留、占用和命令的一致性。
- [ ] Unknown、未完成经济承接及未闭合周期不能提前释放占用；依照 01 的同一权威合同供 09 恢复。
- [ ] 重复组、冲突身份及容量失败不重复预留；覆盖 I2/I3 和 S6-E 的核心事实部分。

## Answer

2026-10-20 用户确认将实现拆为 [05a](05a-multi-account-authority.md) → [05b](05b-joint-admission-occupancy.md)。本票保留原完成条件，作为两张子票的汇总验收，不再独立领取；两票均通过且本票各项证据齐全后才能 resolved，06/07 的外部依赖继续指向本票。架构依据为已 accepted 的 ADR0017，双账户功能仍未实现。
