# 15：Maker–Taker 只读影子验收

Type: task
Status: in_progress
Assignee: Codex
Blocked by: [13 Maker–Taker 独立校准与资格判定](13-maker-calibration.md)
Parent: [模块地图](../map.md)

## Question

以冻结 Maker–Taker 参数只读运行报价及对冲建议链路，独立记录模式运行资格。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 验证候选报价、白名单、撤换建议、时效、健康监测及恢复；无订单或预留副作用。
- [ ] 真实规范输入的捕获/重放保持一致，验证计算预算、缺口和版本撤销；按预登记观察门槛验收。
- [ ] 虚拟maker成交与对冲结果显式标为模拟，不能把未下单的反事实标为真实成交、实际收益或排队证据。
- [ ] 保持 Maker–Taker 独立资格，完成运行证据后列出仍未验证的真实执行风险；缺失观察样本时不关闭。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票为经济或运行资格验收，不是03–11策略开发完成的前置条件。真实数据和运行证据要求保留；外部不足时本票保持未完成，不回退已验收的策略开发状态。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-28：用户明确无真实数据/真实市场，授权完成可开发离线范围。已实现独立Maker只读影子工具，复用14捕获、预算、容量和实际重放；私有副本运行11 Cycle/报价及真实maker checkpoint，不返回可编码Action或Intent，不调用资金/预留/发送。

开发公开回归覆盖候选/白名单、原生Post-only模拟建议、正常撤换终态约束、增量对冲与Unknown恢复、健康/缺口/版本撤销和原对象不变。所有虚拟成交/对冲均为counterfactual_simulation，真实排队、实际Fill及PnL未观察。详见[15证据](../maker-shadow-evidence.md)。

仅工具开发完成；上方真实观察验收条件保持未勾选。13真实经济资格依赖保留，本票in_progress，运行资格pending。

