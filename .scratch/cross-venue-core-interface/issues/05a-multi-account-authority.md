# 05a：多账户权威表示与持久恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 权威边界](01-authority-boundary.md)
Parent: [模块地图](../map.md)

## Question

如何在单 DecisionDomain / TradingShard 中按账户分区拥有权威状态，并通过公共持久恢复路径证明归属不混淆？

## What to build

依照 [ADR0017](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md) 和 [权威设计](../authority-design.md)，贯通账户分区、组合经济归属、Instrument 路由、资金租约、命名空间及全链路格式演进。本票不开放双账户组发送；共同准入归 05b，周期终结归 09a。

## 完成条件

- [x] 明确并实现账户、周期、品种、订单/命令/预留、拒绝事实、历史 pin 与快照字节预算；整组预检及独立安全事实容量有公共边界证据。
- [x] 一个合法两账户状态从 `TradingShard.apply(CanonicalEvent)` 经 Owner/Store commit 到 snapshot/restore/replay 保持账户余额、组合账本、订单归属与摘要一致；不能只交付类型。
- [x] 账户/品种/Venue/环境/组合错配、跨 owner 同账户品种竞争配置明确拒绝；单意图入口不能绕过唯一 owner 约束。配置容量能容纳 AB/AC 的共同竞争集合。
- [x] 按账户和 Asset 校验可支用资金、预留与 RiskLease；共享资金租约不重叠，全局预算来源可验证。拒绝跨账户抵扣及无法证明预算来源的配置。
- [x] 核心、canonical、journal/snapshot/registry 与 Gateway 实际受影响的身份分别演进；旧单账户兼容规则明确，不猜测迁移、重用来源身份或混淆相同 command_id。
- [x] append/commit/恢复故障、旧格式、损坏及缺失尾部经公共接缝验证失败关闭；没有半账户发布或未持久发送许可，记录实际命令与局限。

## Answer

2026-10-22 resolved。用户确认完整静态清单及显式域级历史方案后，完成单 owner 四账户分区、独立预算锚点、账户经济/租约/归属与持久恢复。资金费、控制、双账户对账历史贯通域根及实际冷查证；活动周期订单/Fill保持pin，09a前不回收。

公共运行前沿、完整配置满载及全字段编码上界共同验证容量；journal/state/registry为43/47/41，其他格式分别演进，旧格式失败关闭。最终ReleaseSafe **683/683**、真实Python Host文件恢复和Python **5/5**通过，双轴复审无遗留阻断。完整命令、容量修订和逐项证据见[05验证记录](../05-verification.md)。

依照已接受[实现合同](../05a-implementation-contract.md)的产品缺口条款，现有控制面未发布完整清单与独立锚点，多账户产品入口保持关闭，deployment/production qualification=false；这不授予部署、账户额度或交易权限。
