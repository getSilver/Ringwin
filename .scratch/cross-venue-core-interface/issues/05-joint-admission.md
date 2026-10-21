# 05：双账户共同准入与持久占用

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05a 多账户权威表示](05a-multi-account-authority.md)、[05b 共同准入与占用](05b-joint-admission-occupancy.md)
Parent: [模块地图](../map.md)

## Question

如何使完整双腿组仅在两腿和共享资源均合格时共同提交，并在崩溃后保留占用？

## What to build

依照已确认权威设计，将 Host 双腿候选贯通账户/品种/投资组合校验、资金和保证金检查、共享额度与占用、持久提交及命令生成。

## 完成条件

- [x] 两成员的 ExchangeAccount、Instrument、VirtualPortfolio 与路由匹配；不支持的所有权组合明确拒绝。
- [x] 任一腿不合格时不留下半组可发送命令或新预留；共同准入不声称 Venue 原子成交。
- [x] A/B 与 A/C 竞争同账户品种时只能提交一个活动占用；不同品种共享资金不能超用。
- [x] 在准入及持久提交前后注入故障，经公共恢复路径核对组身份、资金预留、占用和命令的一致性。
- [x] Unknown、未完成经济承接及未闭合周期不能提前释放占用；依照 01 的同一权威合同供 09 恢复。
- [x] 重复组、冲突身份及容量失败不重复预留；覆盖 I2/I3 和 S6-E 的核心事实部分。

## Answer

2026-10-22 resolved。[05a](05a-multi-account-authority.md)、[05b](05b-joint-admission-occupancy.md)已完成并逐项验收；单DecisionDomain/Owner实际共同拥有多账户候选、预留、命令与持久占用。原票六项完成条件的公共证据、格式、实际命令和局限见[05验证记录](../05-verification.md)。最终ReleaseSafe **683/683**，真实Python Host文件恢复通过，双轴复审无遗留阻断。

解除06/07及09a的本票核心依赖，不代表Venue原子成交、完整策略或部署资格。现有产品配置发布缺口按已接受合同记录，多账户产品入口保持关闭；周期释放仍须09a闭合证据。未部署、未执行真实或Demo交易。
