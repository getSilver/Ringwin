# 10：真实策略状态 checkpoint 与恢复

Type: task
Status: resolved
Assignee: Codex issue10 agent
Blocked by: [09 双 IOC 完整交易周期](09-dual-ioc-cycle.md)
Parent: [模块地图](../map.md)

## Question

将实际预测模型、冻结计划、信号和周期状态接入现有 checkpoint，证明连续运行和恢复的一致性。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [x] 复用 PortableStrategyStateJsonV1 和既有 codec，不使用 pickle 或任意浮点 JSON；核心事实仅保留引用。
- [x] 覆盖 S6-A–P的本票策略侧范围；基线及已实现挑战模型分别验证模型均值/协方差、成熟标签队列、信号及风险状态。Maker未实现部分由11扩展，逐项边界见证据。
- [x] 连续执行、不同批次、不同 checkpoint 切点及重复输入得到相同 StrategyStateDigest、下一序号与意图；非法状态/版本/容量拒绝。真实Host数据帧尾重放移交集成。
- [x] 在 tick、概率及止盈原子边界两侧核验完全相同判定；容差不能掩盖恢复后改变交易决策。
- [x] 策略侧恢复承接原预留引用、原期限、退出阶段及锁存，停机计时不归零；当前权限/显式恢复输入不得由checkpoint替代。真实旧输出/激活拒绝仍由核心公共接缝验收。
- [x] 提供真实 Python Host子进程搬运实际组件checkpoint、旧会话/缺尾拒绝证据及核心08/09b的真实模型验证材料；核心日志尾/激活接线明确移交独立集成验收，不相互等待整票关闭。
- [x] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

实际核心 checkpoint 和激活路径属于独立集成验收；本票按版本化合同及已有 codec 独立验证策略恢复，不等待核心08/09b整票关闭。

## Answer

2026-10-28完成Python策略开发范围，详见[真实策略恢复证据](../strategy-recovery-evidence.md)。实际模型/窗口、标签、信号、监测、未决准入和双IOC周期接入版本2严格codec，v1兼容保留；不复制核心经济权威。

公开恢复18/18、Python全量172/172通过，compileall和diff检查通过。两个独立子代理分别复核Standards/Spec；共发现3项初审P2及1项补审阶段兼容P2，均先加公开失败回归再修复，最终两轴确认无剩余发现并核对相同代码SHA256。

只关闭本票Python离线范围；真实日志尾/激活、核心持久预留/经济结果及跨平台数值/经济/运行资格继续pending。未部署、未真实或Demo交易、未外部写入；下一Frontier是11，本代理不认领。

