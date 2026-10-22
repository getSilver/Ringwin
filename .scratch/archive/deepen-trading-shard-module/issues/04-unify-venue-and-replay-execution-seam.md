# 04 — 让 Venue Adapter 与无副作用重放共用执行 seam

**What to build:** 让 SimulatedVenue 与 OKX 只消费 TradingShard 产生的 OrderCommand，并把 OrderDispatchResult 与规范 CanonicalEvent 返回同一个 apply interface；历史重放复用相同核心转换，但不具备发送任何 Venue 副作用的能力。

**Blocked by:** 02 — 以可配置 Genesis 闭合核心 apply interface

**Status:** resolved

- [x] SimulatedVenue 与 OKX 均不能直接修改 TradingShard；提交、未知结果、回报和对账只能作为规范输入返回 apply。
- [x] Adapter 专有字段、传输时序和调度状态不进入 AuthoritativeTradingState 或 CanonicalStateDigest。
- [x] 同一规范执行事实经 SimulatedVenue、OKX 事实映射与 semantic replay 后得到等价的核心结果。
- [x] replay 构造和运行路径不持有可发送的 VenueAdapter，因而不能重发 OrderCommand 或其他外部副作用。
- [x] 本票不把独立现货经济投影提前迁入核心；完整双层经济闭合仍由后续地图票据负责。
