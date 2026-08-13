# 06 — 证明切换故障安全与 ForwardRollback

**What to build:** 在版本切换的每个持久边界和外部事实等待点注入崩溃，证明恢复后只能明确选择旧版本、新版本或 RecoveryOnly；新版本已经产生成交后，回滚也必须作为当前 barrier 上的新一次正向切换执行，永不恢复旧经济状态、旧序号或历史策略实例。

**Blocked by:** 05 — 通过 CutoverDrain 与 CutoverBarrier 原子激活版本

**Status:** done

- [x] 在 candidate 加载/迁移、Quiescing、撤单发送前后、Unknown 对账、最终 barrier、VersionActivationEvent 写入/确认前后分别注入故障；恢复结果没有双活、半激活或代码/状态版本混搭。
- [x] 激活事实之前失败会丢弃 candidate 并从当前权威 barrier 恢复旧版本；激活事实之后失败不会暗中切回，无法证明唯一活动版本时进入 RecoveryOnly 并禁止新增风险。
- [x] ForwardRollback 复用 CutoverDrain、对账和 CutoverBarrier，把旧业务代码作为新的 candidate；发布代次、ShardSequence、订单身份空间及激活历史继续递增，不复活历史 StrategyInstance。
- [x] 新版本产生部分成交、费用、持仓、账本、reservation 或 forced execution 后执行 ForwardRollback，证明这些经济事实既不倒退也不重复，旧代码从当前 AuthoritativeTradingState 继续运行。
- [x] 旧代码不能读取当前 schema 且没有合格影子状态或 Rebuild 历史时，回滚明确失败并保持停止；第一版不以反向 StateMigration 或历史 snapshot 强行降级。
- [x] 一条失败即停的验收入口覆盖 snapshot round-trip、截断恢复、Venue/Unknown 对账、StrategyCheckpoint 追赶、Keep/Migrate/Rebuild、切换故障和成交后回滚，并比较稳定事实、最终状态、CanonicalStateDigest 与经济/风险守恒。
