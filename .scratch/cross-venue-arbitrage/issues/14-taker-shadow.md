# 14：双 IOC 只读影子验收

Type: task
Status: in_progress
Assignee: Codex
Blocked by: [12 双 IOC 样本外校准与资格判定](12-taker-calibration.md)
Parent: [模块地图](../map.md)

## Question

接入实际规范数据只读运行双 IOC 策略，验证时效、计算预算、决策及恢复的运行表现。

来源：[策略规格](01-strategy-spec.md)、[策略合同](../strategy-contract.md)、[算法验证](../algorithm-validation.md)、[参数合同](../parameter-contract.md)、[信号合同](../signal-monitoring.md)及[恢复合同](../state-recovery-contract.md)。2026-10-23 用户确认拆票；策略使用 Python。

## 完成条件

- [ ] 采用冻结合格参数，经真实 Host 输入观察候选、白名单复核、拒绝及状态；断言无可发送意图、资金预留或交易命令。
- [ ] 记录延迟、计算容量、双腿新鲜度、缺口、版本变更、重启及监测动作，并按预登记时长/样本/负载门槛验收。
- [ ] 相同捕获数据离线重放与影子决定一致，边界差异有定位证据，不能隐藏丢弃或超限。
- [ ] 模拟成交/收益与实际可观察事实明确区分，影子不授予真实执行或盈利资格；未实际运行不得关闭。
- [ ] 汇总该模式公式、回放、校准和运行证据及剩余限制；后续交易需另行有界授权。
- [ ] 保存实际命令、输入/版本、结果及局限；未执行项明确标记。公式正确、统计有效和运行资格分别给证据。

## 依赖与边界

2026-10-23范围调整：本票为经济或运行资格验收，不是03–11策略开发完成的前置条件。真实数据和运行证据要求保留；外部不足时本票保持未完成，不回退已验收的策略开发状态。

复用现有 StrategyHost 和核心公共合同；MarketFeedAdapter/VenueAdapter 负责规范输入，核心保持资金、风险、预留、命令及账本权威。开工重新核对当前源码与相关 ADR，不沿用旧交接的缺口结论。ready-for-agent 不取消 Blocked by；本票发布不授权立即实施、部署或真实/Demo交易。

## Answer

2026-10-28：按用户“目前没有真实数据和真实市场，现在是开发阶段；把能做的做了”的澄清，已实现可开发的离线只读驱动、捕获/原始输入归档联合重放、显式运行门槛及监测/真实checkpoint恢复回归。见[14实施证据](../taker-shadow-evidence.md)。

公开入口为 `python/arbitrage_shadow.py` 的 `Protocol/Frame/Session/replay`，复用真实 scanner、Admission、Signal、Monitor 及 Host checkpoint/depth codec；没有发送、预留回调、Intent编码或执行周期入口，不另造核心权威。建议只是不可发送的JSON摘要，合成结果始终 `qualification=false`。

JSON捕获保存规范深度及输入指纹，不单独承载完整研究场景；重放还须提供全部原始不可变Frame归档与相同冻结依赖，再次运行扫描/准入并逐帧核对决定及私有状态。非确定的本机计算耗时不参与决定相等比较。

以上是离线工具完成，不勾选真实验收条件。12冻结合格参数及实际Host/市场输入、预登记真实时长/样本/负载运行、捕获和实测资格均未取得；Blocked by 保留，运行资格pending，本票不关闭。未部署、未真实/Demo交易、未同步GitHub。

