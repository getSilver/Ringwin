# 四分片共享账户协调

Status: open

## Destination

四个单写者 TradingShard 经稳定协议共享 ExchangeAccount、AccountCoordinator 和 Execution Gateway，保持经济归属、毛额风险约束与恢复确定性。

## Definition of done

七张票全部满足原始条件，并通过离线四分片稳定验收；不继承 Venue 或生产资格。

## Rules

按依赖逐票执行；保留单写者边界；所有账户权限只向下收紧；不进行真实或 Demo 交易。

## Route

- [01 — 冻结四分片共享账户协调协议](issues/01-freeze-shared-account-coordination-contract.md)
- [02 — 按 GrossPortfolioMargin 分配 RiskLease](issues/02-allocate-risk-leases-from-gross-portfolio-margin.md)
- [03 — 确定性扇出共享账户与 Venue 事实](issues/03-fan-out-authoritative-account-and-venue-facts.md)
- [04 — 闭合 GrossPortfolioMargin 与 VenueNetMargin 对账](issues/04-reconcile-gross-portfolio-and-venue-net-margin.md)
- [05 — 共享 Execution Gateway 并保持订单唯一归属](issues/05-share-execution-gateway-with-unique-order-ownership.md)
- [06 — 证明局部故障隔离与账户级向下收紧](issues/06-prove-local-isolation-and-account-wide-tightening.md)
- [07 — 闭合四分片恢复与确定性验收](issues/07-close-four-shard-recovery-and-deterministic-acceptance.md)

依赖：01 → 02、03、05；02 + 03 → 04；02 + 03 + 05 → 06；04 + 06 → 07。

## Frontier

- [06 — 证明局部故障隔离与账户级向下收紧](issues/06-prove-local-isolation-and-account-wide-tightening.md)

## Decisions so far

- 2026-10-26：05 原五条离线条件已完成：共享有界批次、逐项结果与唯一 order/command 归属、安全优先级及恢复不重发；最终 Coordinator/Gateway/四 Adapter/四 Owner 矩阵 135/135，双轴复审无剩余必修项。完整套件前 86 项通过，第 87/800 项 cutover 栈溢出；栈与完整资格仍由 07 收口。Frontier 推进到 06，06、07 保持未完成，详见 [05 验证报告](05-validation-2026-10-26.md)。

- 2026-10-26：04 原五条离线功能条件已完成：域内多 VirtualPortfolio、独立经济/历史归属与原生对账，实际成交方向抵消 gross8/native4/benefit4 且不扩张 lease；总专项 123/123、quantum 10/10、订单归档 5/5、forced 历史 3/3、资金费 2/2、500 组合 4/4，双轴复审无剩余功能问题。生产 64 MiB 栈检查失败，完整套件/冻结摘要/栈资格仍由 07 收口，详见 [04 验证报告](04-validation-2026-10-26.md)。05–07 保持未完成。

- 2026-10-24：用户确认本轮补齐同一 DecisionDomain 内多个独立 VirtualPortfolio，再完成原 04/07 的真实方向抵消验收；保留同账户同品种唯一决策域和单写者，详见 [ADR0020](../../docs/adr/0020-own-multiple-portfolios-in-one-decision-domain.md)。04 在经济归属、毛额占用及恢复验收完成前保持未完成。

- 2026-10-23：按当前源码逐票核对，摘要发布版本与真实 ShardSequence 必须分离；未完成验证不得标为 resolved。

- 2026-10-24：01 已按原条件完成；双轴审查发现的持久故障隔离及测试夹具问题已修复，协调器文件 180/180，通过后续显式重新取得资格前不恢复摘要故障账户的租约授权。

- 2026-10-24：02 已完成：毛额包含持仓保证金与 OMS 预留，明确两种屏障，持久租约生命周期与四份新摘要重新取得资格；配置账户及四片公开验收 8/8、协调器 184/184，双轴复审无剩余问题。

- 2026-10-24：03 已按原五条条件完成：持久原文 spool、唯一 wire 归属、部署 funding 证明、冷 fee 历史、逐品种 forced 来源与分配/ACK/归档/恢复；未知事实与源故障独立失败关闭，健康 margin 不可越过。协调器 40/40、扩展场景 23/23、双账户冷 fee 2/2 及最后的 forced Owner 真恢复 2/2 ReleaseSafe；双轴复审无剩余问题。完整套件与冻结摘要由 07 收口。

## Not yet specified

无新增范围；以七张原始票完成条件为准。

## Out of scope

GitHub 同步、Web/CLI 扩展、真实或 Demo 订单、生产资格。
