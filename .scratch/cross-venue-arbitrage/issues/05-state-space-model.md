# 05：状态空间挑战模型回放

Type: task
Status: resolved
Assignee: Codex (strategy/05-06-python-model-evaluation)
Blocked by: [04 滚动统计与 AR(1) 预测回放](04-baseline-prediction.md)
Parent: [模块地图](../map.md)

## Question

在基线相同的输入和评估协议下运行动态中心加回归偏离模型，输出可比较的预测及失败证据。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [x] 实现既定 F/H/Q/R 模型与在线 filtering；验证期不使用 smoothing 或未来观测反向初始化。
- [x] 以独立矩阵递推或高精度基准核验预测和 Joseph 协方差更新；覆盖对称性、半正定性、有限值及数值容差。
- [x] 验证 Q 半正定、R>0、0<phi<1，多起点拟合报告可识别性及退化解；中心漂移不直接认作回归证据。
- [x] 缺口重置与预热仅改变预测状态，不清周期、期限或风险锁存；与基线使用相同时间分区。
- [x] 提供已知状态合成序列及边界回放；冻结运算顺序、版本和参数，不自动启用或混合投票。
- [x] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-27 已完成Python状态空间过滤、Joseph更新、前向预测、有界多起点拟合及诊断报告。
[05验收记录](../state-space-evidence.md)包含源码、独立Decimal矩阵核验、种子/容差、实际结果及局限。
公开测试12/12，Python全量74/74；语法编译与diff检查通过。
标准轴无发现；规格轴发现的“元数据别名冒充不同起点”已修复并经12项公开测试复验，无剩余项。
本票仅关闭Python数学/离线回放范围；合成拟合仍报告参数不可识别，不能自动启用模型。
mypy、真实Host/checkpoint/跨平台资格、市场校准、影子和交易均未执行。

