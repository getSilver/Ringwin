# 定义核心领域词汇、所有权与不变量

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

TradingShard、StrategyInstance、VirtualPortfolio、ExchangeAccount、RiskLease、OrderIntent、Order、ExecutionReport、Position 和 LedgerEntry 的规范含义、所有权关系及不可违反的不变量是什么？

## Answer

规范领域语言记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### Canonical language

- 策略所有权使用 StrategyDefinition、StrategyInstance、VirtualPortfolio 和 DecisionDomain。
- 账户状态明确拆分为 PortfolioPosition / ExchangePosition 及 PortfolioBalance / ExchangeBalance；禁止使用含糊的 Position 或 Balance。
- 交易决策使用单订单 OrderIntent 和多腿 IntentGroup。
- 订单事实链使用 OrderCommand、Order、ExecutionReport、OrderState 和 Fill；MarketTrade 仅代表公开行情成交。
- 账本使用 LedgerTransaction 与 LedgerPosting，取代含糊且无法表达整体守恒的 LedgerEntry。
- 风险权限使用 RiskLease，具体订单占用使用 RiskReservation。
- 交易对象使用 Venue、Asset 和 Instrument；symbol 仅是交易所代码，不是权威身份。
- 无法解释的交易所事实形成 ReconciliationBreak，不能猜测归属。
- TradingShard 是实现 DecisionDomain 单写者所有权的运行时模块，不属于领域词汇表。

### Ownership and invariants

1. VirtualPortfolio 独立于进程及策略版本而存在；同一时刻只有一个 Active StrategyInstance 获得交易授权。
2. 每个 VirtualPortfolio 同一时刻只属于一个 DecisionDomain；每个 DecisionDomain 同一时刻只有一个 Active TradingShard 可修改。
3. VirtualPortfolio 与 ExchangeAccount 是多对多关系，但每个 Order 永久归属于唯一的一对。
4. ExecutionReport、Fill 和 LedgerTransaction 是不可变事实；相同外部事实最多生效一次。
5. OrderState、PortfolioPosition 和 PortfolioBalance 是派生投影，不能被直接覆盖。
6. ExchangePosition 与 ExchangeBalance 是独立交易所投影，不能覆盖策略账本。
7. 增加风险的 OrderCommand 必须拥有有效 RiskLease 和足额 RiskReservation；失效后只允许降低风险。
8. IntentGroup 可以整体通过风险准入，但不承诺交易所原子成交，必须具有部分执行处置政策。
9. 对账差异形成 ReconciliationBreak；解决前相关 ExchangeAccount 禁止增加风险。
10. 人工解决差异必须产生可审计的 LedgerTransaction，不能创建假订单使账面对齐。

## Comments

- 2026-07-25：经逐项领域建模访谈确认并解决。
