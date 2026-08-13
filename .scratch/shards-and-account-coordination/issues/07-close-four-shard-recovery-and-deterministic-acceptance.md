# 07 — 闭合四分片恢复与确定性验收

**What to build:** 用一条失败即停的验收入口运行四个单写者 TradingShard、共享账户协调器和单一 Execution Gateway，覆盖 Genesis、风险租约、账户事实、margin 对账、局部/账户级故障以及 snapshot/replay 恢复，并证明最终稳定事实、摘要和经济风险守恒完全等价。

**Blocked by:** 04 — 闭合 GrossPortfolioMargin 与 VenueNetMargin 对账；06 — 证明局部故障隔离与账户级向下收紧

**Status:** ready-for-agent

- [ ] 四 shard 与协调器的 snapshot/barrier 选择具有明确一致性规则；恢复先重放协调输入和各 shard 稳定日志，再完成账户/Venue 对账，期间全部保持 RecoveryOnly。
- [ ] 恢复重建 RiskLease 版本、GrossPortfolioMargin、VenueNetMargin、AccountNettingBenefit、账户级 gate、per-shard gate、订单和 reservation，不重新发送历史 OrderCommand 或 cancel。
- [ ] 同一 fixture 从 Genesis 全量重放、协调 snapshot 加各 shard 日志尾和进程中途再次崩溃恢复后，得到相同协调 barrier、四个 CanonicalStateDigest 与共享摘要。
- [ ] 自动入口覆盖四 shard 正常交易、方向抵消但不消费净额收益、局部 gap/overload/reconciliation break、账户 lease/margin/gateway 故障、Unknown、重复/冲突及恢复成功/失败轨迹。
- [ ] 验收逐项断言唯一订单归属、单写者状态、GrossPortfolioMargin 上界、RiskLease 不超配、账本闭合、Suspense/ReconciliationBreak 规则及其他 shard 不受局部故障影响。
