# 11：Maker–Taker 完整交易周期

Type: task
Status: in_progress
Assignee: Codex issue11
Blocked by: [10 真实策略状态 checkpoint 与恢复](10-strategy-recovery.md)
Parent: [模块地图](../map.md)

## Question

在公共 Host 与 Post-only 路径上完成报价、逐笔对冲、撤换、退出和恢复闭环。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 仅使用原生 Post-only，普通GTC不能冒充；同maker腿最多一张活跃入场单，撤旧终态及成交核对后替换。
- [ ] 报价使用完整周期成本与对冲深度，换价间隔/次数/寿命有界且不重置周期，安全撤单立即响应。
- [ ] 唯一 Fill 增量扣除在途可能对冲量，验证撤单途中成交、对冲 Unknown、尾差累计、数量上限及重启不重复对冲。
- [ ] 独立核算队列基线、联合条件损益及敞口区间；隐藏量、撤单位置和不利选择进入压力情景，L2不能证明真实排队。
- [ ] 公共事件回放及恢复覆盖所有阶段，复用固定止盈、双概率门槛和退出约束；模式资格独立记录。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

未实施；数学、公共接缝、校准及运行验收均以实际证据为准。

