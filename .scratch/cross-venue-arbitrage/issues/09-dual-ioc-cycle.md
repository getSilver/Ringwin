# 09：双 IOC 完整交易周期

Type: task
Status: resolved
Assignee: Codex 09
Blocked by: [08 白名单准入、多机会分配与信号重评](08-whitelist-allocation.md)
Parent: [模块地图](../map.md)

## Question

Python 经真实 Host 公共路径提出完整双腿组，完成入场、有限修复、持仓、退出及对账的离线闭环。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [x] 策略侧完整双腿组及共同准入响应；第二腿拒绝不抹第一腿事实。实际共同准入/独立发送移交集成验收。
- [x] 已知部分成交、修复次数/价格/损失/期限及Holding前一次冻结；原边界不扩张。
- [x] 核心规范投影注入覆盖报告/Fill顺序、重复及归档覆盖；仅唯一已应用经济投影驱动。真实VenueAdapter公共路径未运行，移交集成验收。
- [x] Unknown保留原身份/预留/可能量，选择零新增交易动作并按原身份查询/超时升级，不重发、不穿零。
- [x] 退出优先级、日损失/回撤原因锁存、外部资金流、当前费用更正、显式残余闭合；永续余量拒绝完成。
- [x] I1–I5、I7–I8的策略输入/输出合同回放及拒绝原因留证；没有实际核心命令/预留产生，公共接缝保持独立pending。
- [x] 测试命令、版本、结果及局限见证据；统计和运行资格未授予。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-28完成Python离线范围：`arbitrage_cycle`公开状态机、08建议及版本/规则/摘要绑定、复用Host完整组codec、有限修复、Unknown安全查询、一次冻结目标、风险/止盈退出与核心闭合响应。21项新公开测试及154项Python全量通过；两轴独立复核发现的1项Spec规则绑定P2已修复并补审通过，Standards无剩余发现。详见[09证据](../dual-ioc-cycle-evidence.md)。

本票resolved仅依据2026-10-23范围调整的策略开发完成口径。真实Host/core/Venue接线、结构化执行配置认证、经济资格及运行资格未运行，保留在[独立集成验收](../integration-acceptance.md)。未部署、未交易、未同步GitHub；下一Frontier为10，本代理不认领。

