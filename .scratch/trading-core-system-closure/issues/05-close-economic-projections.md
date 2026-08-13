# 闭合双层经济投影、账本与账户对账

Type: task
Status: resolved
Assignee: Codex
Blocked by: 04
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何由规范 ExecutionReport、Fill、FundingSettlement、VenueForcedExecution、余额/仓位/margin snapshot 闭合 Portfolio 与 Exchange 双层余额、仓位、成本、费用、PnL、保证金和不可变账本，并让对账差异形成失败关闭事实而不是覆盖本地账本？

## Answer

在唯一 `TradingShard.apply(CanonicalEvent)` interface 内加入有界、无分配、纯定点的经济投影深模块。Fill 只携带 `order_id` 与 Venue 确认的经济数字，Instrument、side 和 Portfolio 归属从 OMS 权威 Order 推导；同一事实原子更新 Portfolio/Exchange 两层投影并各自产生一笔借贷闭合的不可变 LedgerTransaction。

- SPOT 与 isolated/net USDT SWAP 分别维护原币余额、PositionQuantity 与 OpenCost；同向增仓累计成本，部分平仓按移动加权平均成本释放，反向成交先平旧仓再建新成本。
- TradingFee、TradingRebate、FundingSettlement、强制执行 fee/penalty 独立分类，不混入 OpenCost；RealizedPnL 由成交成本派生，UnrealizedPnL 仅由 mark-price valuation 更新，不产生账本事务。
- PortfolioMargin 与 ExchangeMargin 使用同一成交事实、各自的内部/Venue margin rate 投影；两层 margin 可以不同，但归属数量、成本与经济分类必须闭合。
- FundingSettlement 在有唯一 Portfolio 仓位时归属双层；无可靠归属时 ExchangeAccount 仍确认真实余额变化，金额进入 SuspenseAccount 并锁存 ReconciliationBreak。
- VenueForcedExecution 不伪造 Order。能够由强制执行前同方向 PortfolioPosition 唯一归属时双层投影；否则只更新 Exchange 层，未归属金额进入 SuspenseAccount 并锁存 ReconciliationBreak。
- 余额、仓位与 margin snapshot 只与本地 Exchange 投影核对；差异记录稳定 break identity，不覆盖本地账本或 Portfolio 投影，也不会自行清除既有 break。
- Fill、FundingSettlement、VenueForcedExecution 与 snapshot 使用稳定身份做有界语义幂等；冲突重复失败关闭，任一错误通过事件级 candidate 事务回滚。
- 全部经济状态、已见身份、账本事务、SuspenseAccount、ReconciliationBreak 与 valuation 进入 `CanonicalStateDigestV3` 和稳定日志；实时与 replay 使用相同 apply 路径。

TDD 证据覆盖：多次部分成交、费用/返佣、移动平均成本、Realized/UnrealizedPnL、双层 margin、资金费、无归属强制执行、snapshot 不覆盖、重复 no-op、冲突失败及逐事务借贷闭合。

第 06 票消费锁存的 ReconciliationBreak 和 VenueForcedExecution 安全事实形成 KillSwitch/TradingAuthorization 状态机；本票不提前实现操作授权、自动撤单或恢复交易。
