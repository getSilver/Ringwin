# 02 — 以可配置 Genesis 闭合核心 apply interface

**What to build:** 让唯一的 TradingShard 通过版本化 CanonicalEvent 接收有界的 InstrumentRules、MarginRules、账户、VirtualPortfolio、策略和 RiskLease 配置；只有 Genesis 权威事实齐备时，OrderIntent 才能经同一 apply interface 产生有界事实与 OrderCommand。

**Blocked by:** 01 — 提取唯一的 TradingShard 产品模块

**Status:** resolved

- [x] 固定 Genesis 值和单一品种默认值不再暗中决定产品行为；所需配置均来自已验证、版本化且有容量上限的规范事实。
- [x] 缺失、过期、顺序错误或不适用的任一 Genesis 前置事实都会稳定拒绝新增风险，且不会产生 OrderCommand。
- [x] 完整 Genesis 后，原生 OrderIntent 可通过 apply 产生有序、有界的不可变事实和 OrderCommand，相同输入重放得到相同 AuthoritativeTradingState 摘要。
- [x] 本票不引入多 Order OMS、完整经济投影或持久快照恢复；这些能力仍由后续地图票据闭合。
