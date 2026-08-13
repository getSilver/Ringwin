# 01 — 冻结四分片共享账户协调协议

**What to build:** 冻结四个单写者 TradingShard 与一个共享 ExchangeAccount 协调器之间的稳定协议，使每个 shard 只发布自身有版本的风险与经济摘要，并只消费明确归属的账户事实、RiskLease 和向下收紧的 SafetyGate；协调器不得拥有或修改 shard 内订单、PortfolioPosition 或账本。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] 协议为 TradingShard、DecisionDomain、VirtualPortfolio、ExchangeAccount、摘要版本、事实身份和协调 barrier 定义稳定且不可复用的身份；未知、重复冲突、乱序、缺失或跨账户引用均失败关闭。
- [ ] 每个 shard 发布的摘要至少覆盖当前 ShardSequence、规则与 lease 版本、PortfolioMarginReservation、SPOT/SWAP 仓位、账户相关余额、未完成/Unknown 订单和局部 SafetyGate；重复发布相同语义为 no-op。
- [ ] 协调器唯一拥有跨 DecisionDomain 的额度分配与账户核对，不拥有任何 shard 内订单、风险决定、PortfolioPosition、经济账本或 OperationalMode，且不能直接改写 TradingShard。
- [ ] 账户事实、RiskLease 与账户级 gate 通过现有 CanonicalEvent/apply seam 进入 shard；历史重放和协调器恢复不持有 Venue 发送能力。
- [ ] 协议与最小有效/冲突轨迹进入稳定测试，证明相同输入顺序产生相同协调状态、下游事实和摘要。
