# 实现操作生命周期、授权与安全栅栏

Type: task
Status: resolved
Assignee: Codex
Blocked by: 05
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何把 OperationalMode、TradingAuthorization、KillSwitch、TradingPause、CancelOpenOrders、DeRisk/Flatten 和分层 SafetyGate 实现为同一可重放核心状态机，使停止新增风险、撤单、保留仓位、减仓和恢复授权具有明确顺序且危险解除不会越权重开交易？

## Answer

- 新增 `operational.State` 深模块，以稳定身份和语义哈希处理 ControlCommand；重复命令为 no-op，身份或语义冲突失败关闭。OperationalMode、TradingAuthorization、EffectiveTradingAuthority、RiskWarning、恢复资格和拒绝原因均进入权威状态。
- `TradingShard` 统一接入行情连续性、PrimaryLease/RiskLease、双层 MarginSafetyGate、ReconciliationBreak、VenueForcedExecution 与控制事实。独立 gate 按稳定身份原地更新并聚合；KillGate 锁存、WarningGate 定向限制、SelfRecoveringGate 只接受核心可证明的连续性恢复。
- Pause、CancelOpenOrders、KeepPositions、DeRisk/Flatten、Kill 和 Resume 通过同一 OMS seam 执行。增险订单被拒绝时仍提交已经形成的 margin gate 与撤单结果；Flatten 必须先形成明确 RiskWarning；生命周期只在订单、仓位、余额、账本、费用、open cost、对账和 lease 全部闭合后完成。
- 实时与 `ReplayTradingShard` 共用 apply 路径；gate 当前记录、锁存历史、撤单结果、恢复资格和 EffectiveTradingAuthority 进入 `CanonicalStateDigest`，历史 replay 不具备发送副作用的能力。
- 实现提交：`d233cc6`（`Implement operational lifecycle and safety`）。验证通过 `zig fmt --check`、完整 84 项测试以及 ReleaseSafe 构建/运行。
