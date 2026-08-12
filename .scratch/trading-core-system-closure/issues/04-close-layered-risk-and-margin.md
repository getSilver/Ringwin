# 闭合分层风险、现金与逐仓保证金占用

Type: task
Status: open
Assignee:
Blocked by: 03
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何在 OrderCommand 前按 StrategyInstance、VirtualPortfolio、DecisionDomain、ExchangeAccount 和全局层级完成定点风险准入，统一 SPOT 现金、永续逐仓保证金、费用缓冲、open-order/Unknown reservation、双 Reduce-only 与 MarginSafetyGates，并证明占用只由权威事实释放？
