# 01 — 冻结四分片共享账户协调协议

**What to build:** 冻结四个单写者 TradingShard 与一个共享 ExchangeAccount 协调器之间的稳定协议，使每个 shard 只发布自身有版本的风险与经济摘要，并只消费明确归属的账户事实、RiskLease 和向下收紧的 SafetyGate；协调器不得拥有或修改 shard 内订单、PortfolioPosition 或账本。

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] 协议为 TradingShard、DecisionDomain、VirtualPortfolio、ExchangeAccount、摘要版本、事实身份和协调 barrier 定义稳定且不可复用的身份；未知、重复冲突、乱序、缺失或跨账户引用均失败关闭。
- [x] 每个 shard 发布的摘要至少覆盖当前 ShardSequence、规则与 lease 版本、PortfolioMarginReservation、SPOT/SWAP 仓位、账户相关余额、未完成/Unknown 订单和局部 SafetyGate；重复发布相同语义为 no-op。
- [x] 协调器唯一拥有跨 DecisionDomain 的额度分配与账户核对，不拥有任何 shard 内订单、风险决定、PortfolioPosition、经济账本或 OperationalMode，且不能直接改写 TradingShard。
- [x] 账户事实、RiskLease 与账户级 gate 通过现有 CanonicalEvent/apply seam 进入 shard；历史重放和协调器恢复不持有 Venue 发送能力。
- [x] 协议与最小有效/冲突轨迹进入稳定测试，证明相同输入顺序产生相同协调状态、下游事实和摘要。

## Answer / protocol (2026-10-23, verification pending)

- `ShardId` 固定四个槽位；首次发布绑定该槽位唯一的 DecisionDomain、VirtualPortfolio、ExchangeAccount。后续身份漂移、跨账户或跨槽位重复 domain/portfolio 拒绝。协调器不持有可改写 shard 的指针，也不拥有订单、账本或 OperationalMode。
- `publication_version` 是每片从 1 连续递增的摘要发布版本；`shard_sequence` 是 `shardSummaryFromShard` 从 `authoritativeBarrier()` 获取的真实 ShardSequence。发布版本可推进而真实屏障保持不变；相同真实屏障下全部其他摘要语义必须相同。真实屏障、规则版本、lease 版本不得回退。
- `publishSummary(identity, summary)` 的 identity 属于账户协调器全局单调命名空间；每次新发布必须大于所有已保留槽位的 identity。各槽位保留最大身份，因此快照无需无界 seen 集也保留身份高水位。当前 identity 与完整内容精确相同为 no-op；当前 identity 内容冲突拒绝；更早 identity 重用拒绝，不重新授权。
- 摘要字段覆盖规则/lease、PortfolioMarginReservation、SPOT/SWAP 数量、资产与现金、open/Unknown 数量和局部 gate。摘要不是账户净额分配授权。协调器仅拥有跨域分配与核对；账户事实、lease、账户 gate 经现有 CanonicalEvent/apply 投递，接收方保留最终校验与经济状态所有权。
- 每次有效新发布推进独立 coordinator barrier。未知/非法身份、版本缺口、倒序、冲突和错误账户均返回错误。错误不得被解释为新授权；后续票02完善缓存摘要授权失效与新鲜度合同。
- 协调快照版本 12，digest domain `coordinator-history-v11`；旧快照拒绝。publish journal payload 增加显式 publication_version，旧长度由严格解码与尾部完整消费检查拒绝；不提供猜测迁移。恢复默认 RecoveryOnly，重放不持有 Venue 发送能力。

## Verification

- RED: 新公共 publish/restore 回归在旧实现因缺失 `publication_version` 编译失败。
- GREEN: `python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 67108864 --test-filter '01 summary publication'`，2/2。
- `--test-filter 'shard summaries derive'`: 2/2. Public applyAccountGateStable changes the shard gate and authoritativeBarrier; helper preserves the real barrier across repeated publications. No direct OMS mutation remains in this test.
- `--test-filter 'protocol rejects'`: 3/3, existing summary conflict, publication gap, owner drift and cross-shard delivery regressions.
- `--test-filter 'snapshot restores deterministic'`: 2/2, four-shard coordination snapshot and digest equivalence.
- `--test-filter 'widened summary round trips'`: 2/2, summary snapshot/tail round trip and retired-format rejection.
- All commands use prefix `python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 67108864`. Production coordinator semantics were frozen before these final targeted runs. The Windows stack prerequisite belongs to ticket07.
- One full coordinator run compiled 179 tests: first 15 passed, test16 hit the pre-existing nested TradingShard copy stack overflow in handleAssetDefinition. Ticket07 owns that prerequisite; the parent runs the final full suite. No live/Demo orders or production qualification.

## Acceptance mapping / review handoff

1. Identity/version/barrier: separate publication_version, true ShardSequence, global monotonic publication identity, unique ownership and exact duplicate rules; new public publish/restore and existing protocol regressions.
2. Summary: shardSummaryFromShard derives barrier, rules/lease, activeReservationAtoms, SPOT/SWAP/assets/cash, orders and local gate from shard state. The public real-shard test observes a durable gate transition. Same-barrier semantic mutations fail closed. Existing scalar margin fields do not claim ticket04 instrument/bucket reconciliation qualification.
3. Ownership: AccountCoordinator owns summaries, allocations and delivery records; it has no mutable ownership of shard orders, ledger or OperationalMode. Explicit peripheral apply helpers retain shard-owned economic application.
4. CanonicalEvent/apply delivery seams and RecoveryOnly recovery remain; coordinator replay holds no Venue send capability. Full four-shard fact/lease recovery acceptance is rechecked by ticket07.
5. Minimal valid/conflict traces, duplicate digest stability and snapshot equivalence pass the targeted public tests. Final gateway/recovery qualification is not inferred from these checks.

Status remains in-progress pending two-axis review and parent-coordinated commit. Original acceptance requirements are unchanged.


## Review correction: rejected-summary authority fence

The Spec review found P1: a rejected publication previously left cached summaries eligible for fresh leases. RED public regression reproduced four newly granted leases after a rejected conflict.

Any rejected publish now latches `summary_protocol_fault`. allocateLeases and completeRecovery check this fence before other admission. Existing summaries remain unchanged; even a later valid summary cannot clear it. Ticket02 must explicitly requalify all four fresh summaries and must preserve unrelated gates/latches.

CoordinatorOwner commits typed event15 containing the rejected publication identity and full canonical ShardSummary before returning the original validation error. Append/commit failure closes the writer and keeps the memory fence latched. Tail replay reestablishes the fence; checkpoint carries it in snapshot12 and digest domain coordinator-history-v11. A synthetic event can only tighten authority.

The new public regression covers conflict, stale, gap, cross-account rejection, then cached lease denial; Owner checkpoint + rejected publication + tail recovery + subsequent snapshot recovery remain denied. GREEN: `python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 268435456 --test-filter '01 rejected'`, 2/2. Combined `--test-filter '01 '` also passed 3/3 (session92891).

Final strengthening covers repeated identical invalid publication and subsequent valid publication, both retaining the authority fence. Parent rerun of the combined command passed 3/3 after narrowing the persistence-error catch: successfully recording a rejection preserves the writer, while persistence failure closes it. Spec re-review found P1 resolved. Standards found an affected overflow fixture, corrected to use a fresh coordinator for its independent lease-expiry scenario; the full coordinator file is being checked. Status remains in-progress pending final checks and commit. No full-core-suite or production qualification is inferred.

## Closure (2026-10-24)

Standards and Spec reviews completed; the P1 durable fence and P2 independent overflow fixture findings are fixed. Parent verification: python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 268435456 passed **180/180**; final --test-filter '01 ' passed **3/3**. zig fmt --check and git diff --check pass. The full core suite and four-shard application acceptance remain required by ticket07; this closure does not grant Venue or production qualification.
