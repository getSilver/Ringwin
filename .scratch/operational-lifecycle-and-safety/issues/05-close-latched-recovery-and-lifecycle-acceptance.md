# 05 — 闭合锁存解除、显式恢复与整条生命周期验收

**What to build:** 区分 SelfRecoveringGate 与 LatchedSafetyGate 的恢复权限。能够证明状态连续的自恢复条件重新验证后可以继承原 TradingAuthorization；涉及订单、对账、强制执行或身份不确定性的锁存条件即使原因解决也只能回到 Ready，必须由新的 `EnableTrading` 显式恢复。

**Blocked by:** 03 — 把分层 SafetyGate 与 KillSwitch 接入订单权限；04 — 实现 DeRisk 与 Flatten 的受控 Draining 生命周期

**Status:** done

- [ ] SelfRecoveringGate 仅在未产生未知经济或身份事实且连续性可确定证明时继承原授权；不满足条件时自动升级为锁存或保持无授权。
- [ ] LatchedSafetyGate 的解决事实引用原锁存身份并保留历史；解决后范围停在 Ready，新的 `EnableTrading` 仍须通过全部当前 SafetyGate。
- [ ] 行情、租约或其他上级条件恢复不能顺带清除 ReconciliationBreak、VenueForcedExecution 或子级锁存，恢复命令也不能绕过仍关闭的 gate。
- [ ] 完整覆盖 enable、pause、cancel open、keep positions、de-risk、flatten、kill、原因解决和 resume 的成功与失败轨迹，证明只允许规定的新增风险、撤单和 Reduce-only 行为。
- [ ] 实时与 replay 得到相同 OperationalMode、TradingAuthorization、EffectiveTradingAuthority、订单、仓位、锁存历史和 CanonicalStateDigest；历史 replay 不发送副作用。
