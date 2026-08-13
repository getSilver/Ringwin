# 02 — 闭合 TradingPause、CancelOpenOrders 与 KeepPositions

**What to build:** 让 SystemOwner 能持续暂停一个交易范围或一次性撤销其未完成订单。TradingPause 立即停止新增风险，撤销未完成订单，在权威终态和对账完成后停在 Ready；KeepPositions 明确保留既有仓位及经济归属。

**Blocked by:** 01 — 标准化 ControlCommand 与基础交易授权状态机

**Status:** done

- [ ] `CancelOpenOrders` 只发出当前范围所需的 cancel，不改变 OperationalMode；若范围仍处于 Trading，完成后可以再次报单。
- [ ] `TradingPause` 撤销 TradingAuthorization、禁止新增风险并推进撤单；reservation 仅由权威终态释放，存在 Unknown 或未完成对账时不得宣称 Pause 完成。
- [ ] Pause 完成后范围处于 Ready，既有 PortfolioPosition、OpenCost 和账本归属保持不变；KeepPositions 不被解释为 DeRisk 或 Flatten。
- [ ] 重复 ControlCommand 不重复发 cancel，命令冲突失败关闭；实时与 replay 的模式、订单、reservation 和摘要一致。
