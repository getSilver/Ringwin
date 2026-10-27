# 06：固定目标与概率双门槛评估

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [03 完整周期经济计算与精确数量](03-economic-calculation.md)；[04 滚动统计与 AR(1) 预测回放](04-baseline-prediction.md)
Parent: [模块地图](../map.md)

## Question

在联合场景中先生成参考收益及固定目标，再评估实际计划收益和入场/持仓概率，输出候选通过或拒绝证据。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 覆盖 S2-A–F、S3-A–I 及 V6、V10–V13；Pi_reference 只生成一次目标，Pi_plan 用于准入，不回灌降低目标。
- [ ] 场景包含两腿联合价格、深度、延迟、费用和失败结果；log价差不直接当USDT收益，不独立相乘两腿成交率。
- [ ] 验证权重和为1、完整周期净收益、成本缓冲覆盖去重；未闭合尾部与删失不记为零或成功。
- [ ] p_entry 包含零成交及失败场景，p_hold 条件于已知状态；区分合法触发与实际收益达标，同刻风险/到期优先。
- [ ] 概率下界误差来源、有效样本和适用范围有证据；不足拒绝，不以模拟条数充当独立市场样本。
- [ ] 未来 Holding gate 仅使用当时可见信息与冻结估计器，禁止外层未来泄漏和自递归；计算量有界，剩余期限不重置。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

