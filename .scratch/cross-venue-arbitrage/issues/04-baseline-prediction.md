# 04：滚动统计与 AR(1) 预测回放

Type: task
Status: in_progress
Assignee: Codex (strategy/04-python-baseline)
Blocked by: None (can start immediately)
Parent: [模块地图](../map.md)

## Question

从按接收时间可见的规范行情形成固定网格，运行滚动统计与 AR(1) 基线并输出版本化预测和拒绝原因。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 覆盖1秒网格及300/900/3600步预测；迟到数据不改旧决定，缺口不插值、不把跨缺口观测当相邻样本。
- [ ] 用独立解析结果与逐步递推交叉验证条件均值、方差、半衰期；检查时间单位及方向符号。
- [ ] 覆盖近单位根、退化方差、空桶、样本不足和非法参数；不把不合格 phi 裁剪为合格值，不以溢出或 NaN 继续排序。
- [ ] 参数离线拟合并冻结，在线只按版本更新；预测及标签记录可见截止点和成熟时间，固定数据与版本可复现。
- [ ] 合成已知过程验证参数和预测误差，报告容差、种子和有限样本局限；合成通过不等同市场有效。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

