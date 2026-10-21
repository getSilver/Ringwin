# 05a：多账户权威表示与持久恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [01 权威边界](01-authority-boundary.md)
Parent: [模块地图](../map.md)

## Question

如何在单 DecisionDomain / TradingShard 中按账户分区拥有权威状态，并通过公共持久恢复路径证明归属不混淆？

## What to build

依照 [ADR0017](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md) 和 [权威设计](../authority-design.md)，贯通账户分区、组合经济归属、Instrument 路由、资金租约、命名空间及全链路格式演进。本票不开放双账户组发送；共同准入归 05b，周期终结归 09a。

## 完成条件

- [ ] 明确并实现账户、周期、品种、订单/命令/预留、拒绝事实、历史 pin 与快照字节预算；整组预检及独立安全事实容量有公共边界证据。
- [ ] 一个合法两账户状态从 `TradingShard.apply(CanonicalEvent)` 经 Owner/Store commit 到 snapshot/restore/replay 保持账户余额、组合账本、订单归属与摘要一致；不能只交付类型。
- [ ] 账户/品种/Venue/环境/组合错配、跨 owner 同账户品种竞争配置明确拒绝；单意图入口不能绕过唯一 owner 约束。配置容量能容纳 AB/AC 的共同竞争集合。
- [ ] 按账户和 Asset 校验可支用资金、预留与 RiskLease；共享资金租约不重叠，全局预算来源可验证。拒绝跨账户抵扣及无法证明预算来源的配置。
- [ ] 核心、canonical、journal/snapshot/registry 与 Gateway 实际受影响的身份分别演进；旧单账户兼容规则明确，不猜测迁移、重用来源身份或混淆相同 command_id。
- [ ] append/commit/恢复故障、旧格式、损坏及缺失尾部经公共接缝验证失败关闭；没有半账户发布或未持久发送许可，记录实际命令与局限。

## Answer

2026-10-20 由用户确认的 05 拆分发布；实现未执行。设计前置 01 已 resolved，当前可领取。

2026-10-21：执行 05 前按当前源码核对，单账户 Coordinator 的 `global_limit_atoms` 不能证明跨账户额度来源，业务历史根和 Gateway 来源也仍为单账户合同。已形成[实现合同提案](../05a-implementation-contract.md)，待确认静态部署分配清单的信任来源及显式域级历史命名空间；未修改交易代码，未执行功能验收，05a/05b/05 均未关闭。依照 map 的难逆格式与新权威取舍规则，确认后先实施本票。
