来源：`.scratch/shards-and-account-coordination/issues/04-reconcile-gross-portfolio-and-venue-net-margin.md`

**What to build:** 在共享 ExchangeAccount 上同时保留四个 shard 的 GrossPortfolioMargin 与 Venue 报告的 VenueNetMargin，并按账户模式、逐仓 Instrument、保证金桶、风险档位和 liquidation 事实完成确定性核对；净额收益保持不可分配，无法解释的差异形成稳定账户级锁存。

**Blocked by:** 02 按 GrossPortfolioMargin 分配 RiskLease；03 确定性扇出共享账户与 Venue 事实

## 验收标准

- [ ] GrossPortfolioMargin 从全部 shard 毛 reservation 推导，VenueNetMargin 只来自明确 Venue account facts；两者不会互相覆盖或混为同一余额。
- [ ] AccountNettingBenefit 仅记录为 `max(GrossPortfolioMargin - VenueNetMargin, 0)` 的账户观察结果，不归属任何 VirtualPortfolio，也不释放 reservation 或扩大 RiskLease。
- [ ] 对账覆盖账户模式、净 ExchangePosition、ExchangeMarginBucket、margin、风险档位、强平阈值及规则允许的最小单位舍入；未知输入保持 Unknown。
- [ ] 无法解释的数量、保证金、模式或阈值差异形成稳定 MarginReconciliationBreak/LatchedSafetyGate，并向下撤销相关 shard 的新增风险权限，同时保留撤单、对账和合格 Reduce-only 通路。
- [ ] 健康、方向抵消、差异、重复、冲突、原因解决和人工恢复轨迹在协调器与四 shard 重放后得到相同 gate、lease、摘要及经济/风险守恒结论。
