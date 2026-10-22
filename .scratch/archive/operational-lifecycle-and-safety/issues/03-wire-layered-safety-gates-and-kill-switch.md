# 03 — 把分层 SafetyGate 与 KillSwitch 接入订单权限

**What to build:** 在 TradingShard 内由行情、租约、MarginSafetyGate、ReconciliationBreak、VenueForcedExecution 及控制事实计算 EffectiveTradingAuthority。KillGate、强制执行或不确定经济事实锁存 KillSwitch，立即停止新增风险并撤销存量增险订单，同时保留 cancel、必要对账及合格 Reduce-only 通路。

**Blocked by:** 01 — 标准化 ControlCommand 与基础交易授权状态机；02 — 闭合 TradingPause、CancelOpenOrders 与 KeepPositions

**Status:** done

- [x] WarningGate 只禁止继续扩大受影响方向的风险并保留明确状态，不自动撤单、DeRisk 或 Flatten。
- [x] KillSwitch 支持当前 TradingShard 可证明的层级收紧；上级 SafetyGate 只能向下撤销新增风险能力，解除上级原因不能清除子级锁存。
- [x] ReconciliationBreak、VenueForcedExecution 与 KillGate 形成 LatchedSafetyGate；原因消失不会自动清除锁存或恢复 TradingAuthorization。
- [x] KillSwitch 撤销存量增险订单但不自动平仓；cancel、对账及双 Reduce-only 合格的安全命令保有可用通路，普通订单不能耗尽该通路。
- [x] 全部 gate、锁存原因、EffectiveTradingAuthority、撤单结果及恢复资格进入稳定日志和摘要并可确定性重放。
