# 13：Maker–Taker 独立校准与资格判定

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [05 状态空间挑战模型回放](05-state-space-model.md)；[11 Maker–Taker 完整交易周期](11-maker-taker-cycle.md)
Parent: [模块地图](../map.md)

## Question

独立校准 Maker–Taker 的联合成交与对冲模型并输出模式资格，不能继承双 IOC 结论。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 遵守与双 IOC 相同的预登记、时间隔离、生命周期去泄漏及一次保留测试规则，独立记录模式覆盖和参数版本。
- [ ] 取得合法来源的真实成交及条件对冲资料，检验队列假设、部分/零成交、撤单途中成交、不利选择及尾部；不为本票自动发真实或Demo订单。
- [ ] 对成交条件和等待时间联合校准，稀有失败无样本不能按零概率；压力权重不伪称经验概率。
- [ ] 分别校准 Pi_reference/Pi_plan、p_entry/p_hold、数量与报价适用范围及完整占用时间；有效历史块数不以模拟条数替代。
- [ ] 完整样本外策略收益与风险满足预登记标准才可给出模式资格；缺数据保留未完成，影子和L2均不替代真实成交证据。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票为经济或运行资格验收，不是03–11策略开发完成的前置条件。真实数据和运行证据要求保留；外部不足时本票保持未完成，不回退已验收的策略开发状态。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

