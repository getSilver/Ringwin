# 03 — 让原生策略与 Python StrategyHost 共用 OrderIntent seam

**What to build:** 让原生策略和 Python StrategyHost 产生的 OrderIntent 都进入同一个 TradingShard apply interface，接受相同的身份、游标、配置、新鲜度与授权检查，并获得相同语义的拒绝事实或 OrderCommand。

**Blocked by:** 02 — 以可配置 Genesis 闭合核心 apply interface

**Status:** resolved

- [x] 原生与 Python 意图不再经过各自的权威转换路径；二者只能通过同一 CanonicalEvent 和 apply seam 改变 TradingShard。
- [x] 等价意图在相同权威状态下产生等价的规范化、风险决定、拒绝原因和 OrderCommand。
- [x] 旧 session、stale cursor、重复冲突、配置不匹配和未授权意图均失败关闭，不进入风险或 OMS。
- [x] StrategyHost 只拥有显式策略私有状态，不能直接修改订单、风险占用、仓位、账本或核心恢复状态。
