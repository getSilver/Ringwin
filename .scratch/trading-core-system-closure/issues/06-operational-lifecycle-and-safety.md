# 实现操作生命周期、授权与安全栅栏

Type: task
Status: open
Assignee:
Blocked by: 05
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何把 OperationalMode、TradingAuthorization、KillSwitch、TradingPause、CancelOpenOrders、DeRisk/Flatten 和分层 SafetyGate 实现为同一可重放核心状态机，使停止新增风险、撤单、保留仓位、减仓和恢复授权具有明确顺序且危险解除不会越权重开交易？
