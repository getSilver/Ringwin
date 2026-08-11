# 定义账本、PnL 与资金费用分配

Type: grilling
Status: resolved
Blocked by: 13, 14
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

真实账户与策略虚拟投资组合应如何记录余额、仓位、手续费、资金费用、已实现/未实现 PnL、划转及跨币种估值，并保持成交级可审计性？

## Answer

规范账务词汇记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### Ledger units and valuation

- 权威账本按 Asset 及合约计量单位记录原始数量，不隐式换币；USDT 只作为 ReportingAsset。
- 估值不进入账本。ValuationSnapshot 按版本化固定 ValuationRoute 换算；永续使用所属 Venue 的标记价格，现货资产使用指定健康 L2 的买卖中间价。
- 稳定币不假定等值。价格缺失、不健康或过期时保留为未估值状态，不使用无限期旧价或零值。
- 现货资产只通过 PortfolioBalance 计入净值；现货 PortfolioPosition 是成本与 PnL 投影，不能重复计价。线性永续敞口按产品公式加入未结算价值。

### Position cost and PnL

- VirtualPortfolio 对每个 Instrument 使用移动加权平均成本作为权威策略 PnL 成本法。
- 权威成本状态为 PositionQuantity 与 OpenCost，不只保存舍入后的平均价格。同向增仓增加总成本，部分平仓按比例释放成本并把除法余数留在剩余仓位，完全平仓时数量和成本同时归零，反向成交先平旧仓再建立新成本。
- TradingFee、TradingRebate 与 FundingAllocation 不进入 OpenCost。
- RealizedPnL 由不可变成交或结算事实按照 AverageCost 确定性推导，不重复改变余额；UnrealizedPnL 只存在于 ValuationSnapshot。
- 净值变化扣除 CapitalFlow 后的 PnL 与损益分项独立计算并核对；期间 PnL 使用期初、期末累计值之差。未估值资产会使汇总 PnL 明确标记为不完整。

### Fees and funding

- 每个 Fill 的 TradingFee 和 TradingRebate 全部归属该 Order 的 VirtualPortfolio，按 Venue 实际扣收或返还的 Asset 分别入账；后续修正通过冲正或更正事务追加。
- FundingSettlement 以 Venue 结算时点为准。FundingAllocation 根据当时各 VirtualPortfolio 的有效有符号仓位、Venue 资金费率、标记价格及合约规格确定性计算。
- 相反方向的投资组合分别保留应付与应收，不能按真实账户净仓位简单摊薄；分配之和必须与 ExchangeAccount 实际结算核对，舍入尾差进入 TreasuryPortfolio，无法解释的差异形成 ReconciliationBreak。

### Two-layer ownership and transfers

- ExchangeAccount 账本记录 Venue 确认的全部真实经济事实，VirtualPortfolio 账本记录其策略归属。
- 对每个 Asset 和 Instrument，全部 VirtualPortfolio 归属、TreasuryPortfolio 及 SuspenseAccount 之和必须闭合到 ExchangeAccount 账本。
- TreasuryPortfolio 承载未分配自有资金及确定性尾差；无法可靠归属的真实金额进入 SuspenseAccount，并必须关联 ReconciliationBreak。
- ExternalTransfer 表示真实账户边界上的资金移动；PortfolioTransfer 表示同一 ExchangeAccount 内两个投资组合之间同 Asset、等额、原子的归属转移。
- 跨账户划转必须有两端真实事实，跨资产转换属于交易。首版不转移持仓或 AverageCost，也不得用虚构划转消除差异。

### Audit, time and corrections

- 每个 LedgerTransaction 由唯一源经济事实与账务类型确定性生成；重复或乱序回报不能重复入账，全部 LedgerPosting 原子生效。
- 审计链可由 LedgerPosting 反查至 LedgerTransaction、Fill、Order、OrderIntent 及原始接入日志；确定性重放必须得到相同事务身份、金额和归属。
- 事务同时保留经济归属的 EffectiveTime 与系统追加的 RecordedTime。迟到及更正事实不得倒插日志；历史报告通过新修订版本按 EffectiveTime 重算。
- 已记录事实只能由引用原事务的冲正与替代事务更正，不能覆盖或删除。

### Onboarding and exceptional facts

- 首版 ExchangeAccount 采用干净切换：启用前必须零仓位、零挂单并完成快照核对；OpeningBalance 将期初资产默认归入 TreasuryPortfolio。
- 强平、ADL、结算、分摊及人工调账必须显式处理。有真实成交语义时记录 Fill；否则记录 VenueAdjustment，禁止伪造成交。
- 异常事实能可靠定位时归属相应 VirtualPortfolio，否则进入 SuspenseAccount 并形成 ReconciliationBreak。

## Comments

- 2026-07-26：经逐项账务与 PnL 领域建模访谈确认并解决。
