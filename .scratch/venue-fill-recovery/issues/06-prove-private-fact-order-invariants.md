# 固定 report、Fill 与 reconciliation 的顺序不变量

Type: task
Status: resolved
Assignee:
Blocked by: [03 贯通 OKX 私有事实到权威状态](03-integrate-okx-private-facts-through-core.md), [04 证明批次中断后的确定性恢复](04-prove-adapter-batch-crash-recovery.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何以可重复、可诊断的输入排列证明 report、Fill 和 reconciliation 的顺序不会改变权威经济结果，
同时所有非法序列稳定失败关闭？

## What to build

建立一组固定种子的表驱动排列，覆盖单笔和多笔部分成交、累计报告、取消、对账、重复及冲突身份；
每条排列运行 live 与 replay 并比较完整权威摘要。固定矩阵通过后，再以同一不变量增加小规模有界
fuzz，避免随机测试成为唯一证据。

## Acceptance criteria

- [x] 同一唯一 Fill 在所有允许排列中至多影响经济账一次。
- [x] 同一事实集合的不同合法到达顺序产生相同最终 `SemanticAuthorityDigest`；保留其不同的有序 `CanonicalStateDigest`。
- [x] 多笔唯一 Fill 的已应用总量不得超过订单原始数量；等于原始数量的边界成功。
- [x] Venue 累计 report 或 reconciliation 本身不产生 Fill 经济账变化。
- [x] replay 对每条排列均 `writes_sent=0`，并与 live 权威状态一致。
- [x] 相同身份不同 payload 在所有排列中稳定失败关闭，且不留下部分经济提交。
- [x] 数量、费用、余额和累计值的所有组合算术使用 checked arithmetic，并覆盖极值失败路径。
- [x] cancel/reconciliation 已包含累计数量后迟到 Fill 的固定排列不会重复记账。
- [x] 有界 fuzz 使用固定种子、固定最大事件数和可打印的最小失败输入；固定表驱动回归可独立运行。

## Out of scope

- 无界随机 fuzz、长期 soak 或用概率成功替代固定验收。
- 为排列器引入新的属性测试依赖或通用测试框架。

## Accepted digest boundary

[ADR 0009](../../docs/adr/0009-separate-semantic-authority-digest-from-audit-trace.md) retains
`CanonicalStateDigest` for Trace/snapshot integrity and introduces `SemanticAuthorityDigest` for this ticket's
legal private-fact permutations. It must normalize only collection evidence whose identities have already passed
the ordinary conflict checks; it does not relax those checks or replace the canonical digest.

## Progress record

2026-09-22: added the named digest and one fixed, legal two-partial-Fill ordering regression. It keeps the
relative order of distinct Fill postings fixed (weighted-cost posting is ordered), permutes only report/Fill
arrival positions, and checks live/replay plus applied quantity. The full Trace digest intentionally differs.

2026-09-22: completed the fixed matrix in `src/trading_shard_tests.zig`: four legal report placements around two
ordered Fill postings retain `SemanticAuthorityDigest`, intentionally differ in `CanonicalStateDigest`, apply the
two unique Fills exactly once to the original order quantity, and prove replay has no outbound write. The same
matrix rejects a duplicate Fill identity with a changed payload before the live digest changes. A 32-case bounded
fuzz (seed `0x06_2026_0922`, at most six events) varies the partial quantity and legal placement; any regression
prints the seed, case, split and arrival order. Fixed cancel/reconciliation rows prove a single late Fill is
applied once whether it arrives before or after terminal cancellation/reconciliation. Existing shard/OMS/economics
and account-projection checked-arithmetic extreme tests run in the same targeted suite. `zig test
src/trading_shard_tests.zig` and `zig test src/trading_shard_tests.zig -OReleaseSafe` each passed 116 tests;
`zig fmt --check` and scoped `git diff --check` passed. No online write or `src/main.zig` run occurred.
