# 03 — 确定性扇出共享账户与 Venue 事实

**What to build:** 让 ExchangeAccount 的余额、净仓位、margin、风险档位、强制执行及账户对账事实只从共享 Venue 接入消费一次，再按明确身份、归属和固定顺序扇出到受影响 TradingShard；任何 shard 不得自行重复接入或猜测账户事实。

**Blocked by:** 01 — 冻结四分片共享账户协调协议

**Status:** resolved

- [x] 每个账户事实绑定 ExchangeAccount、Venue 事实身份、观察范围、版本和协调 barrier；语义重复为 no-op，身份冲突、乱序和缺口失败关闭。
- [x] 可唯一归属的 Fill、fee、funding、forced execution 和 reservation 只投递其所有 shard；账户总量与 margin 事实按稳定 shard 顺序扇出，且每个 shard 仍通过自身 apply 更新权威状态。
- [x] 无法唯一归属的经济事实进入既有 SuspenseAccount/ReconciliationBreak 路径，不按比例、净仓位或当前余额猜测 Portfolio 归属。
- [x] 单个 Venue fact 只在共享接入层解码/规范化一次；四 shard 不复制 Adapter、网络会话、认证状态或 Venue order book。
- [x] 广播、单播、重复、冲突、中途崩溃及恢复重放轨迹产生相同 per-shard sequence、经济状态、gate 和摘要，且不重发外部副作用。

## Implementation evidence — verified, 2026-10-24

The shared ingress now stores original canonical facts in authenticated typed history, retains semantic identity evidence beyond the resident window, and uses independent durable shard acknowledgement cursors. The four-Owner fixture exercised broadcast, forty facts pending for one domain while another domain progresses, snapshot recovery, and the crash window between the target commit and coordinator acknowledgement. A failed acknowledgement write remains quarantined on recovery.

Canonical funding retains immutable deployment ownership evidence and rejects forged account, instrument, domain and configuration bindings during snapshot recovery. Other domains' deployed instrument rules can be registered for account observation validation; trading ownership remains domain-specific. The economics module passed 63/63 ReleaseSafe tests. The earlier shared-delivery scope passed 11/11 in Debug and ReleaseSafe; subsequent fee-proof, account-fault and expanded Gateway fixture changes still require final verification.

The real Gateway fixture now runs four configured Owners with colliding local order/command numbers through one Gateway and one simulated VenueAdapter. Dispatch results, Fill and execution reports route by the qualified wire identity and matching order/command; only the owner changes. The fixture verifies reservation release, an attributed fee revision and duplicate, forged wire/order attribution entering the existing account ReconciliationBreak, all Owner checkpoints, recovered Gateway bindings and no replay send. It exposed and fixed account-wide source identity collisions, missing wire identity in dispatch results, and incomplete dispatch evidence during snapshot validation. Canonical/journal/state/registry versions are now 17/48/52/46.

Historical and live unmapped fills now preserve native account/trade/client/fee evidence without inventing a local order, including the reconciled backlog without an economic cutoff. The public backlog regression reproduced a silent drop before the fix. The OKX-focused scope passed 25/25 ReleaseSafe; the private decoder module passed 32/32 ReleaseSafe. These are scoped checks, not the final suite.

Canonical forced execution now carries an explicit Venue category, native execution/order/bill references, instrument and rule units, source envelope, and optional PnL/fee/penalty evidence. The OKX public REST and WS seams retain signed execution IDs without inventing liquidity or a per-execution penalty from cumulative liqPenalty. Incomplete facts remain immutable account Suspense with the existing ReconciliationBreak. See the [official OKX API guide](https://www.okx.com/docs-v5/en/).

The existing typed forced allocation/Owner apply/ack/history protocol now carries the canonical source and instrument-specific contribution cut. A real Gateway and simulated Venue fixture opens instruments 1 and 5, applies the forced source only to 5, keeps the other position, charges fee 1 plus penalty 2 once, survives the Owner-commit-before-ack crash window, archives the full source, and recognizes its cold duplicate after a newer account fact. Later Venue facts wait behind an unresolved forced source. The source and archive encoding buffers were enlarged after public regressions exposed their previous bounds.

A separate closed-cycle Owner/Gateway fixture verifies fee-origin history lookup after actual fill reclamation and Owner recovery, including exact match, conflict, injected history I/O failure, coordinator recovery and one actual fee application. It covers both primary account 20 and secondary account 30 and preserves the other account. This exposed and fixed primary-account-only assumptions in shared delivery and fee attribution. The attempted in-flight-cycle archive was correctly rejected; the test uses an existing genuinely closed-cycle fixture instead of weakening that guard.

Malformed initial stream/source identities fail closed without binding a source namespace. Account faults retain immutable lease grant identities and versions. Current lease delivery, direct allocation, margin-gate resolution and recovery completion all reject an unresolved Venue fault: a fresh healthy margin observation cannot erase unknown economic evidence. The final public regression reproduced that authorization bypass and passed in Debug and ReleaseSafe after the fix.

Validation: the coordinator-focused scope passed 40/40 ReleaseSafe; the expanded 03 scope passed 23/23 ReleaseSafe; closed-cycle cold-fee verification for both configured accounts passed 2/2 ReleaseSafe; the final permission regression passed 2/2 in Debug and ReleaseSafe. An additional real forced Owner checkpoint/recovery case passed 2/2 ReleaseSafe, comparing the same checkpoint barrier, unchanged economic state and no second charge before coordinator ACK. Standards and Spec independent reviews, including the permission fix, report no remaining findings against the user-approved c46fb483598b81ff6f659bc8531f34afa97b45ae baseline.

These checks close the five original conditions above. The complete module suite remains scheduled for ticket 07 after all seven tickets; these are not production or Venue qualification. An earlier broad imported-module run reached the frozen-trajectory digest mismatch and was stopped during unrelated file-fault loops; it is not a passing full suite. Frozen acceptance digests remain unchanged pending complete recovery/economic assertions. Account-gate cause-specific recovery remains the original scope of ticket 06, with its explicit handoff note.
