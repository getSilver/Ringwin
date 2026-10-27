# 09：双 IOC 完整交易周期

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [08 白名单准入、多机会分配与信号重评](08-whitelist-allocation.md)
Parent: [模块地图](../map.md)

## Question

Python 经真实 Host 公共路径提出完整双腿组，完成入场、有限修复、持仓、退出及对账的离线闭环。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 验证完整双腿共同准入及独立发送；第二腿失败不回滚第一腿事实，不以两个独立新风险请求替代完整组。
- [ ] 覆盖已知部分成交、修复次数/价格/损失/期限，Holding 前只冻结一次缩放目标；原目标与风险边界不扩张。
- [ ] 从 VenueAdapter 公共输入覆盖报告/Fill 两种顺序、重复、迟到、归档重复；仅唯一已应用经济增量驱动动作。
- [ ] Unknown 保留身份、预留和可能量，不换身份重发；动作对可能成交情形均安全，不穿零。
- [ ] 退出优先级、日损失/回撤锁存、外部资金流、实际费用更正和残余承接可对账；永续残仓不完成周期。
- [ ] 覆盖 I1–I5、I7–I8 相关路径，记录命令、预留、净敞口及拒绝原因；仿真与公共接缝证据分别保存。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

