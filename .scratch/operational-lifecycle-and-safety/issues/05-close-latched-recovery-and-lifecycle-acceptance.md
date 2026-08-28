# 05 — 闭合锁存解除、显式恢复与整条生命周期验收

**What to build:** 区分 SelfRecoveringGate 与 LatchedSafetyGate 的恢复权限。能够证明状态连续的自恢复条件重新验证后可以继承原 TradingAuthorization；涉及订单、对账、强制执行或身份不确定性的锁存条件即使原因解决也只能回到 Ready，必须由新的 `EnableTrading` 显式恢复。

**Blocked by:** 03 — 把分层 SafetyGate 与 KillSwitch 接入订单权限；04 — 实现 DeRisk 与 Flatten 的受控 Draining 生命周期

**Status:** done

- [x] SelfRecoveringGate 仅在未产生未知经济或身份事实且连续性可确定证明时继承原授权；不满足条件时自动升级为锁存或保持无授权。
- [x] LatchedSafetyGate 的解决事实引用原锁存身份并保留历史；解决后范围停在 Ready，新的 `EnableTrading` 仍须通过全部当前 SafetyGate。
- [x] 行情、租约或其他上级条件恢复不能顺带清除 ReconciliationBreak、VenueForcedExecution 或子级锁存，恢复命令也不能绕过仍关闭的 gate。
- [x] 完整覆盖 enable、pause、cancel open、keep positions、de-risk、flatten、kill、原因解决和 resume 的成功与失败轨迹，证明只允许规定的新增风险、撤单和 Reduce-only 行为。
- [x] 实时与 replay 得到相同 OperationalMode、TradingAuthorization、EffectiveTradingAuthority、订单、仓位、锁存历史和 CanonicalStateDigest；历史 replay 不发送副作用。

## 实现记录（KeepPositions seam 轨迹证据）

- **Seam 接线**：`stop_keep_positions` 在 TradingShard apply seam 内获得专属 fail-closed 校验（`src/trading_shard.zig` `.control_command` 分支）：命令应用前后捕获并比对分组的全量权威经济快照（swap/spot 双层仓位与 open cost、组合/金库/交易所现金、三层费用、已实现/未实现 PnL、账本事务/划转计数与双层借贷、完整 economic projection 摘要、DeRisk 目标位），任何漂移即 `KeepPositionsEconomicsChanged`；若带 `cancel_increasing_only` 或模式未停在 stopped 即 `KeepPositionsMisreadAsDeRisk`，随后强制 `assertClosures()`。KeepPositions 因此不可能被解释为 DeRisk/Flatten，也不会触碰仓位或账本归属。
- **专项轨迹**：`trading_shard.test "keep positions stops through shard seam preserving economics"` — 成功轨迹：有仓有单时 KeepPositions 撤销唯一未完成订单、停于 stopped，并通过共享断言对整个经济快照做深度等值比较；失败轨迹：错目标/过期/版本不匹配 fail-closed、重复命令零事实零撤单、stopped 下新增风险与 Reduce-only 意图均被拒、EnableTrading 被拒；带未解决锁存时仍可停机，重启必须走 start_recovery→recovery_completed→逐个 resolve_latch（含 lease gate 因连续性断裂自动升级为锁存）→新的 EnableTrading。全程 sealed journal 重放摘要一致。
- **整条生命周期验收**：`trading_shard.test "full lifecycle trajectories authorize only prescribed risk cancel and reduce behavior"` — 一条失败即停轨迹串起 cancel open（撤单不改模式、可重新报单）→ pause（虚假 progress 被拒、权威终态后才 Ready）→ enable → 真实成交建仓 → keep positions（保留仓位、拒绝一切交易意图、重复零副作用）→ 恢复 → de-risk 到 40（增量订单 DeRiskTargetViolation、减量成交后凭 progress 完成）→ flatten 无警告被拒、凭 RiskWarning 归零 → kill 锁存（enable 失败、仅剩 Reduce-only）→ 原因解决回 Ready 不恢复授权 → 显式 resume；每阶段只放行规定的新增风险/撤单/Reduce-only 行为，最终 live/replay trace 与 CanonicalStateDigest 全等且重放不重发副作用。
- **验证**：`zig test src/trading_shard.zig`（88/88）、`src/account_coordinator.zig`（100）、`src/recovery_cutover.zig`、`src/strategy_host_*` 及 operational 全部通过；`zig fmt --check` 干净。
