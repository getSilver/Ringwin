# 04 — 闭合 GrossPortfolioMargin 与 VenueNetMargin 对账

**What to build:** 在共享 ExchangeAccount 上同时保留四个 shard 的 GrossPortfolioMargin 与 Venue 报告的 VenueNetMargin，并按账户模式、逐仓 Instrument、保证金桶、风险档位和 liquidation 事实完成确定性核对；净额收益保持不可分配，无法解释的差异形成稳定账户级锁存。

**Blocked by:** 02 — 按 GrossPortfolioMargin 分配 RiskLease；03 — 确定性扇出共享账户与 Venue 事实

**Status:** resolved

- [x] GrossPortfolioMargin 从全部 shard 毛 reservation 推导，VenueNetMargin 只来自明确 Venue account facts；两者不会互相覆盖或混为同一余额。
- [x] AccountNettingBenefit 仅记录为 `max(GrossPortfolioMargin - VenueNetMargin, 0)` 的账户观察结果，不归属任何 VirtualPortfolio，也不释放 reservation 或扩大 RiskLease。
- [x] 对账覆盖账户模式、净 ExchangePosition、ExchangeMarginBucket、margin、风险档位、强平阈值及规则允许的最小单位舍入；未知输入保持 Unknown。
- [x] 无法解释的数量、保证金、模式或阈值差异形成稳定 MarginReconciliationBreak/LatchedSafetyGate，并向下撤销相关 shard 的新增风险权限，同时保留撤单、对账和合格 Reduce-only 通路。
- [x] 健康、方向抵消、差异、重复、冲突、原因解决和人工恢复轨迹在协调器与四 shard 重放后得到相同 gate、lease、摘要及经济/风险守恒结论。

## 已确认方向与历史验收边界

- [ADR 0017](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md) 要求争用同一账户品种的新增周期入口共置或拒绝。`src/trading/deployment_allocation.zig:138` 拒绝重复 portfolio/domain，`:167-170` 对同一 account + instrument 的重复 ownership 返回 `ConflictingDeploymentOwnership`。
- 当前真实四 Owner + 共享 Gateway/VenueAdapter 验收为四个不同 Instrument 各成交一个订单、各保留另一个订单的 OMS reservation：GrossPortfolioMargin = 12，原生 initial VenueNetMargin = 4，观察差额 = 8；该差额来自 OMS 预留，不能作为跨 VirtualPortfolio 方向抵消的证明。
- 用户已确认本轮补齐同一 DecisionDomain / TradingShard 内的多 VirtualPortfolio，再完成真实方向抵消验收；继续保留 ADR 0017 对同 account + instrument 的单 Writer 约束，不开放跨 Domain 竞争。原始五条验收条件保持原文；2026-10-26 完成下述离线功能验收后勾选，生产与平台资格仍由 07 收口。
- 2026-10-25：新增真实四 Owner 公共验收 `multi_portfolio_netting_acceptance.zig` 已在 Debug 通过：Domain 1 内 VP11 与 VP15 经 Host Gateway 完整双腿分组、共享 Execution Gateway、同一个 SimulatedVenue Adapter 实际成交；两品种分别保留 A+3/B-1 与 A-3/B+1，物理净仓各为2单位。GrossPortfolioMargin=8，独立原生账户保证金事实 VenueNetMargin=4，观察收益=4；RiskLease=25、剩余额度=17均不增加，Coordinator及四Owner checkpoint/recover 摘要一致。该证据来自实际成交方向抵消，不使用尚未成交的 OMS reservation 冒充抵消。不同策略配置版本、组合B费用/归档与来源篡改回归仍在进行。

## Answer — 2026-10-26

已完成同一 DecisionDomain 内多个独立 VirtualPortfolio、唯一 Writer 下的毛额风险与原生净保证金对账。真实四 Owner 离线链经 Host 完整组、共享 Gateway 和同一 SimulatedVenue Adapter 实际成交，得到 Gross=8、VenueNet=4、AccountNettingBenefit=4；lease=25、remaining=17 不增加，Coordinator 与四 Owner 恢复摘要一致。原有 Gross=12/native=4 的 OMS 预留差额不作为方向抵消证据。

补齐组合独立授权/资金/费用/残差、二级账户归档、三组合规范登记顺序、强制执行原生与组合成本差额、来源篡改拒绝、撤权后的热重复、ACK 与冷历史/恢复路径。未知归属保持 Suspense，未知原生输入不授予新增风险。

最终 ReleaseSafe 总专项 123/123、native quantum 10/10、既有四个订单/Gateway 归档场景 5/5、forced 历史故障/错误证明 3/3、旧资金费精确回归 2/2、500 组合/四 Owner/100 在途订单 4/4；Debug 实际四 Owner 链 3/3、forced 专项 5/5、Bybit 私有对账 8/8。固定基线 c46fb483598b81ff6f659bc8531f34afa97b45ae 的 Standards/Spec 并行审查及修复后复审无剩余功能问题。完整命令、源码身份和限定见 [验证报告](../04-validation-2026-10-26.md)。

资格边界：生产栈仍为 64 MiB，新增实际链在该 reserve 的 Debug/ReleaseSafe 检查发生栈溢出，未取得生产可运行资格；已补记到 [07](07-close-four-shard-recovery-and-deterministic-acceptance.md)。完整仓库套件、冻结验收及该栈问题由 07 完成。本票只关闭原始离线功能条件，不关闭 05–07，不继承生产资格；未做真实或 Demo 交易，也未同步 GitHub。
