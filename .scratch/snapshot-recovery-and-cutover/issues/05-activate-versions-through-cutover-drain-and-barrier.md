# 05 — 通过 CutoverDrain 与 CutoverBarrier 原子激活版本

**What to build:** 让策略、参数或 TradingShard 核心版本切换先在无交易权限的 candidate 中完成 Keep/Migrate/Rebuild 与影子验证，再于明确 ShardSequence 上停止受影响范围的新 intent、撤单并对账，最终以持久化 VersionActivationEvent 原子替换活动版本，避免双活或代码与状态版本混搭。

**Blocked by:** 03 — 以 Venue 对账闭合重启恢复权限；04 — 在恢复 fence 后追赶 StrategyCheckpoint

**Status:** ready-for-agent

- [ ] Keep 只接受相同且语义兼容的 StateSchemaVersion；Migrate 仅运行明确的确定性纯迁移并通过结构、经济摘要和策略自定义不变量；Rebuild 在历史不足时保持 WarmingUp，三者都不能修改 AuthoritativeTradingState。
- [ ] candidate 合格后受影响范围进入 Quiescing，停止新 OrderIntent，并执行 CutoverDrain：核心切换撤销 DecisionDomain 全部未完成订单，策略或参数切换只撤销该 StrategyInstance 的订单。
- [ ] 撤单权威终态、Unknown 和 Venue 对账未闭合时不跨越 barrier；当前权威核心继续处理其间成交、费用和经济事实，candidate 追到最终 barrier 后再次验证相同 CanonicalStateDigest。
- [ ] VersionActivationEvent 记录旧/新 release、StrategyInstance/definition、参数版本、StrategyStateTransition、StateSchemaVersion、CutoverBarrier 和 CanonicalStateDigest，并在新版本获得新增风险权限前稳定提交。
- [ ] barrier 前只有旧版本权威，barrier 后只有新版本权威；策略代码变化创建 StrategySuccessor，单纯参数变化保留实例身份，单策略切换不暂停同 shard 的无关策略。
- [ ] 有/无活动订单的 Keep、Migrate、Rebuild 及未知 schema/非法迁移轨迹证明不会双活、不会重复副作用，实时与恢复回放以最后一条有效 VersionActivationEvent 得到相同活动版本与摘要。
