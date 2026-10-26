# 06 — 证明局部故障隔离与账户级向下收紧

**What to build:** 证明单个 TradingShard 的行情 gap、队列过载、StrategyHost 故障或局部 ReconciliationBreak 只冻结其 DecisionDomain，而共享账户 lease、margin、凭证或对账故障会通过明确账户级 gate 确定性收紧全部相关 shard；故障解除不能越权清除局部锁存或恢复人工授权。

**Blocked by:** 02 — 按 GrossPortfolioMargin 分配 RiskLease；03 — 确定性扇出共享账户与 Venue 事实；05 — 共享 Execution Gateway 并保持订单唯一归属

**Status:** resolved

- [x] 单 shard gap、inbox 满、Host stale/overload 和局部订单对账差异不改变其他 shard 的 ShardSequence、订单、lease、授权或处理顺序。
- [x] ExchangeAccount lease 失效、MarginReconciliationBreak、凭证或共享 gateway 不可信时，账户级 SafetyGate 以固定顺序投递全部相关 shard，并立即阻止新增风险及撤销规定范围订单。
- [x] 一个过载 shard 不阻塞其他 shard 消费共享市场/账户事实或提交合格命令；共享外围容量耗尽时产生逐项、可归属的稳定 backpressure 事实。
- [x] 上级账户 gate 恢复只移除该上级限制，不清除 shard 内 LatchedSafetyGate，也不自动恢复 TradingAuthorization；各 shard 独立完成原因解决和人工 resume。
- [x] 局部与账户级故障交错、重复、冲突和恢复轨迹在 live/replay 中保持相同 per-shard 状态、共享协调状态、撤单结果和摘要。

## Answer — 2026-10-26

原五条离线条件已完成，当前源码 ReleaseSafe 专项 **118/118**；标准和规格双轴复审无剩余必修项。实现与逐条证据见 [06 验证报告](../06-validation-2026-10-26.md)。公开 Owner 接缝覆盖实际四分片发送、撤单、局部隔离、逐项背压、两账户限制、漏收恢复、人工恢复、控制历史保留及 snapshot/tail replay。

03 的 forced ingress handoff 由 `CoordinatorOwner.resolveVenueGate` 收口：完整热/冷 source、贡献、分配和 ACK 证据，加上四片已消费的新完整账户快照及健康 margin 证据，才能显式解除；未知、协议故障、冲突或不可查证仍失败关闭，不清本地锁存、不恢复授权。Core journal/state/registry 为 `50/54/48`，Coordinator 快照为 18；旧格式拒绝，见 [ADR0021](../../../docs/adr/0021-preserve-account-safety-causes-through-recovery.md)。

完整套件尝试在既有 cutover 第 87/812 项栈溢出；最终完整套件、四分片冻结摘要及生产 64 MiB 栈资格仍由 [07](07-close-four-shard-recovery-and-deterministic-acceptance.md) 收口。本票不授予 Venue 或生产资格，未执行真实或 Demo 交易。


## Handoff from 03 — unresolved account gate lifecycle

The new Venue ingress keeps its broken flag sticky after unknown facts or source faults. A complete forced source also first enters the immutable targets-zero spool before typed allocation, so its economic allocation/ack can close while that ingress flag still holds currentLeaseEvents closed. This must be covered by the original account-gate recovery clauses here: distinguish unresolved/protocol faults from fully proved forced closure; require fresh authoritative evidence and explicit resolution; never clear a shard latch or restore TradingAuthorization as a side effect. Preserve the source/contribution/slice/ack history proof and reject a conflicting or unavailable closure. The current code is fail-closed; 03 does not claim account-wide reauthorization.
