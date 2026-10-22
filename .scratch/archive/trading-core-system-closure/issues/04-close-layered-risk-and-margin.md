# 闭合分层风险、现金与逐仓保证金占用

Type: task
Status: resolved
Assignee: Codex
Blocked by: 03
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何在 OrderCommand 前按 StrategyInstance、VirtualPortfolio、DecisionDomain、ExchangeAccount 和全局层级完成定点风险准入，统一 SPOT 现金、永续逐仓保证金、费用缓冲、open-order/Unknown reservation、双 Reduce-only 与 MarginSafetyGates，并证明占用只由权威事实释放？

## Answer

新增无分配、无 `f64` 的纯定点风险计算模块，并把它放入 `TradingShard.apply(CanonicalEvent)` 到 OMS `OrderCommand` 之间。调用方的 reservation 字段不再具有权威性；核心按版本化规则、当前现金/仓位、活动订单和五层额度计算并覆写它。

- SPOT buy 占用最坏价格现金加费用，SPOT sell 校验组合资产且只占费用；isolated/net USDT SWAP 分别计算 VenueInitialMargin、InternalInitialMargin、维持保证金与平仓费用缓冲。
- StrategyInstance、VirtualPortfolio、DecisionDomain RiskLease、ExchangeAccount 和 global 五层额度全部检查，任一未知、无效或超限都不产生 OrderCommand。
- PortfolioReduceOnly 与 VenueReduceOnly 根据虚拟仓位和账户净仓位独立推导，组合减仓但账户增险时不会错误设置 VenueReduceOnly。
- Opening、Warning、Kill 三档 MarginSafetyGate 使用 Portfolio/Exchange 两层 buffer；本票输出确定性门槛结果，KillSwitch 状态机及自动撤单由第 06 票消费。
- place/amend/CancelConfirmCreate 使用同一计算；amend 取旧、新 reservation 较大值，避免替代窗口重叠释放。
- `Unknown`、pending cancel 和 filled 持续保留占用；只有未发送拒绝、明确 canceled/rejected、confirmed absent 或后续经济事实重算才能释放或转为持仓占用。
- 规则、五层限制、双 Reduce-only、两层 buffer 和活动 reservation 进入版本化 canonical input 与当前 `CanonicalStateDigest`，实时和重放结果一致。
- TDD 复审补证：SPOT/SWAP 各自使用独立的 Portfolio/Exchange 仓位；组合与 Venue 的 Reduce-only 独立推导并写回最终命令；组合减仓但账户增险仍占用 VenueInitialMargin；Opening/Warning/Kill 同时按绝对金额、名义价值 bps 与 liquidation-distance ticks 取最严格结果；维持保证金和平仓费用不会在 OMS 汇总后丢失。

第 05 票继续负责多 Portfolio 的完整经济投影、ExchangeMarginBucket、逐项成交后的真实余额/保证金/账本闭合；本票不预建跨币种、组合保证金或 Venue 规则插件。
