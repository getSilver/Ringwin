来源：`.scratch/trading-core-system-closure/issues/08-shards-and-account-coordination.md`（当前 frontier）

## Question

如何让四个单写者 TradingShard 在共享 Execution Gateway 和 ExchangeAccount 下保持确定性归属、全局额度租约、GrossPortfolioMargin/VenueNetMargin 核对、账户事实扇出与局部故障隔离，且不复制 Venue 接入或让任一分片消费 AccountNettingBenefit？

## 详细需求

展开于子票「shards-and-account-coordination 01–07」：

1. **01 冻结共享账户协调协议** — 稳定不可复用身份体系；per-shard 摘要；协调器只拥有跨 DecisionDomain 额度分配与核对
2. **02 按 GrossPortfolioMargin 分配 RiskLease** — 非抵消毛额总和；lease 授予/续期/收紧/到期/撤销为可重放事实；AccountNettingBenefit 不进入任何可用额度
3. **03 确定性扇出共享账户与 Venue 事实** — 单次消费共享接入，按身份与固定顺序扇出；无法归属进 Suspense/Break
4. **04 GrossPortfolioMargin vs VenueNetMargin 对账** — 双口径严格分离；差异形成 MarginReconciliationBreak/LatchedSafetyGate
5. **05 共享 Execution Gateway 与订单唯一归属** — 完整 fencing identity，发送前 fail-closed；gateway 只拥有调度/限流/传输
6. **06 局部故障隔离与账户级向下收紧** — 局部故障只冻结本 DecisionDomain；账户级故障按固定顺序投递全部相关 shard
7. **07 四分片恢复与确定性验收** — 一条失败即停入口；三种恢复路径产出相同 barrier、4 个 CanonicalStateDigest 与共享摘要

对应地图 Definition of done 第 7 条。完成后 map 前进到 09。
