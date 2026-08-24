08 已开工，分支 `08-shards-and-account-coordination`(基线 dc288f3)。

## 现状核对

历史提交中协调器主体(`src/account_coordinator.zig`)已覆盖子票 01–07 的核心语义,基线 107 项测试全绿(含 12 项协调测试:协议冲突拒绝、毛额租约、原子分配、事实扇出、双口径对账+锁存、gateway 唯一归属、局部隔离/账户级收紧、四分片快照恢复与恢复栅栏)。

## 本次发现的缺口与修复

子票 01 要求"每个 shard 发布自身摘要",但此前摘要只由测试 fixture 手工构造,**没有从 TradingShard 权威状态派生的 seam**——生产路径上摘要是凭空的。本次新增:

- `shardSummaryFromShard()` (src/account_coordinator.zig):从 shard 权威状态确定性派生发布摘要,覆盖 ShardSequence、规则/lease 版本、PortfolioMarginReservation(layered_risk_reserved_micros)、SPOT/SWAP 仓位、账户余额、未完成/Unknown 订单数、局部 SafetyGate(latch/margin gate);未配置账户、规则版本缺失、portfolio 缺失一律 fail-closed。
- 新增测试「shard summaries derive from authoritative state and coordinate four real shards」:四个真实配置的分片 → 派生摘要 → 协调器发布/租约分配(500 reservation 后 used=500、限额不超配)/健康对账(AccountNettingBenefit 仅记为 500 观察值,不进任何额度)/锁存 gate 使 local_gate_closed 翻转;相同输入顺序重放产生相同协调 digest。

验证:`zig test src/main.zig` Debug 与 ReleaseSafe 各 **108 项测试全部通过**(基线 107 + 新增 1)。已提交 ef6a055。

## Multica 票务同步(已完成)

- RING-2 完成交易核心系统闭环(map 父票,in_progress)
- RING-3 闭合四分片与共享账户协调(map 08,in_progress)
- RING-4~10 子票 01–07(01 todo;02–07 backlog,blocked_by 已写入 metadata)
- RING-11 map 09(backlog)、RING-12 map 10(backlog)

## 下一步

按 frontier 规则继续 08 剩余验收核对:02 的显式收紧(tighten)语义、04 对账中 margin_mode/MarginBucket 覆盖、07 一条失败即停的整波验收入口。完成后更新 map.md Decisions 并关闭 RING-3。
