# 08：白名单准入、多机会分配与信号重评

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [07 只读机会扫描与候选展示](07-opportunity-scanner.md)
Parent: [模块地图](../map.md)

## Question

显式批准配对后才允许进入交易评估，使用最新条件选择数量、分配预算并执行信号重评。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 沿用现有 Web 控制面显式启用两腿 ExchangeAccount/Instrument、方向及合格模式；扫描器没有批准权，未批准不发意图。
- [ ] 加入白名单后重新校验行情、费用、模型、资金及信号；过期扫描结果不补发。禁用停止新增周期，保留存量退出与对账。
- [ ] 有界合法 lots 网格选择合格 Pi_plan 最大者；独立小规模穷举核验网格内选择，覆盖非单调收益、容量与确定性并列，不宣称全局最优。
- [ ] Score 用精确比较，预留后重算剩余候选；分账户资金、集中度和共享品种不超用，预留未知按原身份核查。
- [ ] 覆盖 S4 参数校验及 S5-A–M：迟滞、冷却、有界重评、机会期限、窗口去重、证据不足及原因隔离；成功预留消费信号。
- [ ] 配置缺失、过期、非法范围及版本不匹配拒绝新增风险；新增风险门槛不阻断既有安全管理。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

