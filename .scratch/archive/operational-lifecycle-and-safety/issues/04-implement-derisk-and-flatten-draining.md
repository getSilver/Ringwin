# 04 — 实现 DeRisk 与 Flatten 的受控 Draining 生命周期

**What to build:** SystemOwner 可对明确范围和目标敞口发起 DeRisk；该范围进入 Draining，先撤销不再合格的增险订单，再只产生通过最新双 Reduce-only 与风险核验证的减仓命令。目标敞口为零时形成 Flatten，但它仍是独立的人工操作，不由 KillSwitch 自动触发。

**Blocked by:** 02 — 闭合 TradingPause、CancelOpenOrders 与 KeepPositions；03 — 把分层 SafetyGate 与 KillSwitch 接入订单权限

**Status:** done

- [x] DeRisk 记录明确目标敞口、范围、命令身份和前置版本；同一范围及其锁定子范围同时存在第二个 LifecycleOperation 时失败关闭，KillSwitch 仍可随时收紧权限。
- [x] 增险挂单先撤销；后续减仓命令同时满足 PortfolioReduceOnly、VenueReduceOnly、最新仓位事实和当前风险限制，不能通过调用方标志绕过核心推导。
- [x] 部分成交、重复事实、Unknown 和对账结果只按权威事实推进；达到目标且相关订单、仓位、余额与对账闭合后才离开 Draining。
- [x] Flatten 仅是目标敞口为零的 DeRisk，发起前形成明确 RiskWarning；KillSwitch、TradingPause 与 KeepPositions 均不得隐式触发 Flatten。
- [x] 完成、失败和重放轨迹产生相同的 LifecycleOperation、模式、订单、经济状态及摘要。
