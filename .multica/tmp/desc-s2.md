来源：`.scratch/shards-and-account-coordination/issues/02-allocate-risk-leases-from-gross-portfolio-margin.md`

**What to build:** 让共享账户协调器依据四个 shard 的权威 PortfolioMarginReservation 毛额、AccountSafetyCeiling 和全局限制，确定性授予、续期、收紧、到期或撤销各 DecisionDomain 的 RiskLease；任何 Venue 净额收益都只作为观察差额，不能增加任一 shard 的购买力。

**Blocked by:** 01 冻结四分片共享账户协调协议

## 验收标准

- [ ] GrossPortfolioMargin 严格等于全部有效 shard reservation 的非抵消总和；缺失、陈旧、冲突或不完整摘要时不分配新增额度。
- [ ] 每份 RiskLease 绑定 ExchangeAccount、DecisionDomain、版本、有效 barrier、额度上限和稳定身份；续期、收紧、到期与撤销均形成可重放事实。
- [ ] 全部 RiskLease 上限及已用 reservation 不得超过 AccountSafetyCeiling/global 上限；并发申请以固定顺序得到确定结果，容量不足时稳定拒绝而非超配。
- [ ] AccountNettingBenefit 不进入 free balance、StrategyLimit 或 RiskLease 可用额度；方向相反的 PortfolioPosition 仍按毛额占用。
- [ ] 四 shard 的授予、收紧、到期、重复、乱序及毛额超限轨迹在 live/replay 中得到相同 lease、拒绝原因、SafetyGate 和摘要。
