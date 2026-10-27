# 07：只读机会扫描与候选展示

Type: task
Status: resolved
Assignee: Codex
Blocked by: [06 固定目标与概率双门槛评估](06-target-probability.md)
Parent: [模块地图](../map.md)

## Question

提供可单独只读运行的 Python 扫描模块，在观察范围发现白名单外配对并展示候选证据。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [x] 复用经济及预测评估实现，输出稳定配对身份、方向、建议模式、数量、收益风险、数据截止点、模型版本和有效期。
- [x] 观察范围与交易白名单分离；发现、展示、刷新候选均不输出交易意图、不预留资金、不自行批准白名单。
- [x] 按配对/方向/模式去重，旧候选失效；证据不足可显示待验证，不能显示已具交易资格；现货/现货仅观察。
- [x] 按下述范围调整，验证策略侧输入→候选→展示JSON及过期/缺口/错误响应；已核对现有Web只读provider，实际路由/页面接线移交独立集成验收，未执行浏览器端到端。
- [x] 同一规范输入在扫描与交易评估中产生相同计算口径，数学基准沿用前置票；固定版本的扫描回放可复现。
- [x] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票以Python公开接口、数学测试及离线合同回放作为策略开发完成条件。上述涉及Web、核心、Host、Venue真实接入的条目只在本票验证策略侧输入/输出与错误响应，实际跨模块证据移交[独立集成验收](../integration-acceptance.md)，不阻塞本票关闭。外部票仅作为合同来源与集成交接；复用已有codec/framing，不复制权威账本、预留或OMS。测试驱动器注入规范事实，不证明核心已满足合同；未知合同须记录缺口。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-28 在用户指定分支 `spread-arbitrage-strategy-python` 完成Python只读扫描、
规范观察配对枚举、共享06经济/预测评估、三模式独立证据、稳定身份、数量去重选择、
候选完整替换及展示过期处理。所有候选交易资格恒为false，无意图、资金预留或白名单批准能力。

[07验收记录](../opportunity-scanner-evidence.md)包含输入合同、实际命令、固定回放hash及Web接线缺口。
扫描11/11、Python全量116/116、语法编译及diff检查通过。
本票仅关闭Python策略/离线展示合同范围；真实Web/Host/Venue集成、市场统计及运行资格未通过，
仍由独立集成验收与12–15负责。未部署或执行Demo/真实交易，未同步GitHub。

