来源：`.scratch/shards-and-account-coordination/issues/06-prove-local-isolation-and-account-wide-tightening.md`

**What to build:** 证明单个 TradingShard 的行情 gap、队列过载、StrategyHost 故障或局部 ReconciliationBreak 只冻结其 DecisionDomain，而共享账户 lease、margin、凭证或对账故障会通过明确账户级 gate 确定性收紧全部相关 shard；故障解除不能越权清除局部锁存或恢复人工授权。

**Blocked by:** 02 按 GrossPortfolioMargin 分配 RiskLease；03 确定性扇出共享账户与 Venue 事实；05 共享 Execution Gateway 并保持订单唯一归属

## 验收标准

- [ ] 单 shard gap、inbox 满、Host stale/overload 和局部订单对账差异不改变其他 shard 的 ShardSequence、订单、lease、授权或处理顺序。
- [ ] ExchangeAccount lease 失效、MarginReconciliationBreak、凭证或共享 gateway 不可信时，账户级 SafetyGate 以固定顺序投递全部相关 shard，并立即阻止新增风险及撤销规定范围订单。
- [ ] 一个过载 shard 不阻塞其他 shard 消费共享市场/账户事实或提交合格命令；共享外围容量耗尽时产生逐项、可归属的稳定 backpressure 事实。
- [ ] 上级账户 gate 恢复只移除该上级限制，不清除 shard 内 LatchedSafetyGate，也不自动恢复 TradingAuthorization；各 shard 独立完成原因解决和人工 resume。
- [ ] 局部与账户级故障交错、重复、冲突和恢复轨迹在 live/replay 中保持相同 per-shard 状态、共享协调状态、撤单结果和摘要。
