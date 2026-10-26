---
status: accepted
date: 2026-10-24
---

# 在同一决策域内拥有多个投资组合

用户选择在本轮补齐同一 DecisionDomain 内的多个 VirtualPortfolio，再验收真实方向抵消。一个 TradingShard 的唯一 decision Writer 按同一确定顺序拥有这些投资组合，各自保留账本、PortfolioPosition、订单归属及风险额度；同一 ExchangeAccount 的真实账户投影只保留一份。

本决定扩展每个决策域仅容纳一个投资组合的实现限制，保留 ADR0017 的竞争放置约束：争用同一账户品种的入口必须共置或拒绝，不引入跨 shard 共同提交。GrossPortfolioMargin 按各投资组合的持仓及未完成订单毛额计算；真实净仓位的方向抵消可以降低 VenueNetMargin，但 AccountNettingBenefit 只供观察，不释放投资组合占用或扩张 RiskLease。

## Considered Options

- 域内多个投资组合、一个写者：沿用现有顺序与持久事务边界，代价是扩展投资组合归属、经济投影及恢复格式。
- 多个决策域共享同一账户品种：需要另立跨写者共同提交与恢复协议，本轮不采用。
- 以订单预留和净保证金的差额代替方向抵消：无法满足原票的真实多投资组合抵消条件，不采用。

## Consequences

订单、成交、资金费、费用及强制执行的归属必须到达具体 VirtualPortfolio；物理账户事实不得复制为多份资产。恢复必须保留原投资组合归属、毛额占用与唯一历史，不通过重放重新授权或发送订单。不兼容的持久格式须升级并失败关闭。

账户净仓与投资组合毛仓的损益实现时点可能不同；该现金差额作为不可分配的 NettingSettlement 保留，不能记入 TreasuryPortfolio 或当作方向抵消收益释放。相同估值时点下，账户现金与未实现损益之和必须等于各投资组合现金与未实现损益、TreasuryPortfolio 及已记录 SuspenseAccount 的合计。

本决定不代表实现或资格已经完成；[第 04 票](../../.scratch/shards-and-account-coordination/issues/04-reconcile-gross-portfolio-and-venue-net-margin.md) 保持未完成，直到真实四 Owner 场景中的域内反向持仓、独立经济归属、毛额风险约束及恢复通过公共接缝验收。
