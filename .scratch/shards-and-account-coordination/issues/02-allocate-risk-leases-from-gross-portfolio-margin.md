# 02 — 按 GrossPortfolioMargin 分配 RiskLease

**What to build:** 让共享账户协调器依据四个 shard 的权威 PortfolioMarginReservation 毛额、AccountSafetyCeiling 和全局限制，确定性授予、续期、收紧、到期或撤销各 DecisionDomain 的 RiskLease；任何 Venue 净额收益都只作为观察差额，不能增加任一 shard 的购买力。

**Blocked by:** 01 — 冻结四分片共享账户协调协议

**Status:** resolved

- [x] GrossPortfolioMargin 严格等于全部有效 shard reservation 的非抵消总和；缺失、陈旧、冲突或不完整摘要时不分配新增额度。
- [x] 每份 RiskLease 绑定 ExchangeAccount、DecisionDomain、版本、有效 barrier、额度上限和稳定身份；续期、收紧、到期与撤销均形成可重放事实。
- [x] 全部 RiskLease 上限及已用 reservation 不得超过 AccountSafetyCeiling/global 上限；并发申请以固定顺序得到确定结果，容量不足时稳定拒绝而非超配。
- [x] AccountNettingBenefit 不进入 free balance、StrategyLimit 或 RiskLease 可用额度；方向相反的 PortfolioPosition 仍按毛额占用。
- [x] 四 shard 的授予、收紧、到期、重复、乱序及毛额超限轨迹在 live/replay 中得到相同 lease、拒绝原因、SafetyGate 和摘要。


## Answer / implementation (2026-10-24, verification pending)

- `shardSummaryFromShard` 使用权威 PortfolioPosition margin 加 OMS active reservation 的 checked sum，避免完全成交后订单预留归零导致 GrossPortfolioMargin 丢失持仓占用。净方向与 AccountNettingBenefit 不增加额度。
- 四份 `granted_publications` frontier 随成功分配持久保存；每次新 grant/renewal 必须四片 publication 全部推进。固定 shard 槽位顺序、均分额度及尾差政策不变；容量不足原子拒绝。版本必须超过每片 lease 高水位，不能只比较第一片。
- 摘要故障保存 `fault_publications` frontier；显式 `requalify_summaries` 事实必须获得最新故障之后四份新摘要，仅解除 summary protocol fence，不解除 RecoveryOnly 或账户核对 gate。
- `expire_leases` / `revoke_leases` 是 typed durable inputs；关闭权限保留真实 reservation 和版本高水位。`tightenLeases` 只缩额度及期限，不以旧摘要延长授权。
- lease 显式区分协调 deadline 与目标 shard deadline：后者在分配时由摘要真实 ShardSequence 加协调剩余 barrier 距离形成，checked overflow。`riskLeaseEventForShard` 校验目标 shard/account/domain，并复用已安装 deployment allocation binding；`applyRiskLeaseStable` 经已有事务 apply seam 交付。
- Coordinator snapshot 13 / digest domain v12；旧快照拒绝。新增 typed journal events 16 expiry、17 revoke、18 summary requalification，不猜测迁移旧格式。
- 保留 ticket07 提供的两个 `noinline` 私有 helper 注解，属于 Windows 有界栈前置工作，不改变经济或协调语义。

## TDD / validation so far

- RED: `02 renewal requires four fresh summary publications` 在旧分配器发现没有新摘要仍可续期版本2。
- GREEN: focused `--test-filter '02 '` 首轮 4/4（含 entry）；其后加强 Owner.apply -> tail/checkpoint recover 的 expiry/revoke、故障 requalification 公共 seam 证据，最终结果待记录。
- 首轮完整 coordinator 182 项：180 passed、2 failed；失败为旧 fixture 只刷新一片即续期、tightening 后复用版本2。已按新合同更新四份新摘要与高水位版本3的 live/replay 输入，最终完整复跑待记录。
- 命令：`python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 268435456`。该256MiB为独立测试 runner 配置，不替代应用进程64MiB证明。
- 实际 configured DecisionDomain lease 与四片稳定交付由父代理在公共 acceptance seam 补充；最终全套、Standards/Spec review 与提交由父代理统一执行。无真实/Demo/GitHub操作。

原始完成条件保留；未完成最终验证及审查前不设 resolved。


## Final coordinator verification (2026-10-24)

- `python tools/zig-entry.py test src/portfolio/account_coordinator.zig -O ReleaseSafe --stack 268435456`: **184/184 passed**, exit 0 (session 16666). Includes final zero-quota, actual Owner durability and requalification tests, plus all imported regression suites. `zig fmt` and scoped `git diff --check` pass.
- 实际摘要测试在刷新 publication 时保持真实 ShardSequence，不能使用 synthetic fixture 的 withSequence 回退真实屏障；聚合/live/replay 回归已通过。
- Owner 生命周期回归：grant1 -> expire21 -> 四份新摘要 -> grant3 -> revoke30 -> tail recover / checkpoint recover；版本4、closed、used100、frontiers 与 digest 全部保留，恢复仍 RecoveryOnly。
- Owner 故障重新取得资格回归：错误账户摘要持久 fence；零份或三份新摘要拒绝；第四份后显式事实仅解除摘要故障，已有 margin break 继续拒绝 grant；快照恢复保持同一 digest。
- 零额度分片形成 closed lease，tighten/revoke-headroom 到0同样关闭；只有精确的 last allocation version/deadline 且未被后续 lease 变化替代才作为 grant duplicate。last request 参与快照与 digest。
- Secondary account mapper 使用已有分区只读借用获得确切 settlement asset，并校验安装配置中的 account/slice，避免复制大型 AccountState；父代理真实配置公共测试已通过 primary20、owned secondary30、foreign999 及恢复。
- 父代理报告实际四 shard 交付、完全成交且 OMS 预留0时保留 literal 10,978,000 atoms margin、三路径恢复相等均通过；原 frozen hash 因授权摘要变化而不匹配，尚未刷新。完整四片 tighten/expiry/duplicate/regrant 轨迹及两个 Core seam 审查修复由父代理完成后，才可关闭本票。

## Closure (2026-10-24)

Standards and Spec re-review have no remaining findings. Public integration closes both review gaps: configured primary/secondary accounts retain exact allocation bindings across closure and a newer grant; four real shards consume grants, duplicates, tightening, stale rejections, expiry, fresh regrant and revocation, then reproduce leases, gates, reservations, summaries and canonical digests through replay. Static slice oversubscription and positive open-lease increases remain rejected. Duplicate risk leases produce no new durable facts.

Parent command python tools/zig-entry.py test src/testing/acceptance/core/risk_lease_delivery_acceptance.zig -O ReleaseSafe --stack 268435456 --test-filter '02 ' passed **8/8**. The coordinator file passed **184/184**. Formatting and scoped diff checks pass. The application fixture also now delivers actual leases to all four shards and independently checks that a fully filled order retains 10,978,000 atoms of position margin after OMS reservations reach zero.

The application at its real 64 MiB stack reaches the final frozen digest check after recovery equality; the expected digest is intentionally not refreshed until tickets03-07 settle. This is not full core-wave, Venue or production qualification.
