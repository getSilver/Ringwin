# 把 fixture 形状的 TradingShard 深化为产品核心模块

Type: task
Status: open
Assignee:
Blocked by: 01
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何在不建立第二套核心的前提下，把当前 `src/main.zig` 内由固定 Genesis 和单一品种驱动的 TradingShard 深化为小 interface、显式依赖、可配置但有界的产品模块，使原生策略、Python StrategyHost、SimulatedVenue、OKX 和重放都只穿过同一 seam？
