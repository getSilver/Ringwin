来源：`.scratch/shards-and-account-coordination/issues/03-fan-out-authoritative-account-and-venue-facts.md`

**What to build:** 让 ExchangeAccount 的余额、净仓位、margin、风险档位、强制执行及账户对账事实只从共享 Venue 接入消费一次，再按明确身份、归属和固定顺序扇出到受影响 TradingShard；任何 shard 不得自行重复接入或猜测账户事实。

**Blocked by:** 01 冻结四分片共享账户协调协议

## 验收标准

- [ ] 每个账户事实绑定 ExchangeAccount、Venue 事实身份、观察范围、版本和协调 barrier；语义重复为 no-op，身份冲突、乱序和缺口失败关闭。
- [ ] 可唯一归属的 Fill、fee、funding、forced execution 和 reservation 只投递其所有 shard；账户总量与 margin 事实按稳定 shard 顺序扇出，且每个 shard 仍通过自身 apply 更新权威状态。
- [ ] 无法唯一归属的经济事实进入既有 SuspenseAccount/ReconciliationBreak 路径，不按比例、净仓位或当前余额猜测 Portfolio 归属。
- [ ] 单个 Venue fact 只在共享接入层解码/规范化一次；四 shard 不复制 Adapter、网络会话、认证状态或 Venue order book。
- [ ] 广播、单播、重复、冲突、中途崩溃及恢复重放轨迹产生相同 per-shard sequence、经济状态、gate 和摘要，且不重发外部副作用。
