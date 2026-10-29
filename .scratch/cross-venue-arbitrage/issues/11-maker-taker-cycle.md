# 11：Maker–Taker 完整交易周期

Type: task
Status: resolved
Assignee: Codex issue11
Blocked by: [10 真实策略状态 checkpoint 与恢复](10-strategy-recovery.md)
Parent: [模块地图](../map.md)

## Question

在公共 Host 与 Post-only 路径上完成报价、逐笔对冲、撤换、退出和恢复闭环。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [x] 仅使用原生 Post-only，普通GTC不能冒充；同maker腿最多一张活跃入场单，撤旧终态及成交核对后替换。
- [x] 报价使用完整周期成本与对冲深度，换价间隔/次数/寿命有界且不重置周期，安全撤单立即响应。
- [x] 唯一 Fill 增量扣除在途可能对冲量，验证撤单途中成交、对冲 Unknown、尾差累计、数量上限及重启不重复对冲。
- [x] 独立核算队列基线、联合条件损益及敞口区间；隐藏量、撤单位置和不利选择进入压力情景，L2不能证明真实排队。
- [x] 公共事件回放及恢复覆盖所有阶段，复用固定止盈、双概率门槛和退出约束；模式资格独立记录。
- [x] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-28：完成Python策略及离线合同范围，详见[11实际证据](../maker-taker-cycle-evidence.md)。新增 `arbitrage_maker` 原生Post-only建议、完整周期报价、剩余量换价、逐笔净增量hedge/Unknown/尾差、独立队列及联合压力、全阶段真实v2 checkpoint恢复；复用06固定目标双门槛与09有限退出，不复制权威OMS/预留/账本。

20项Maker公开测试通过；Python全量192项通过，compileall仅作语法验证。Standards审查无发现；Spec初审1项P2（在途减仓敞口区间）已TDD修复，最终双轴补审无剩余发现。真实Host取消接口/原周期关联、Venue原生Post-only、唯一Fill/账本及恢复激活接线仍按[独立集成验收](../integration-acceptance.md)pending；人工研究夹具不授予12/13经济资格或14/15运行资格。未执行部署、真实/Demo交易或GitHub同步，未认领12以后；模块地图仍open。

