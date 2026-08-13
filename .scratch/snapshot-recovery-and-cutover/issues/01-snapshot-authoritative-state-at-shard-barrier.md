# 01 — 在 ShardSequence barrier 快照权威交易状态

**What to build:** 让 TradingShard 只在已经完整应用的 ShardSequence barrier 上生成稳定、版本化且带摘要的 AuthoritativeTradingState snapshot，并能严格验证和恢复同一 barrier 的完整权威状态；任何未知版本、截断、损坏或摘要冲突都失败关闭，不能以部分状态启动。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] snapshot 记录稳定身份、StateSchemaVersion、Release/SchemaRegistry 身份、ShardSequence barrier、活动配置与规则版本、内容长度、校验值及 CanonicalStateDigest；编码不包含指针、allocator、连接、墙钟或其他临时运行状态。
- [ ] snapshot 覆盖当前 TradingShard 的订单与身份集合、reservation、双层经济投影与账本、风险与 lease、OperationalMode/TradingAuthorization、全部 SafetyGate、锁存历史、恢复资格、活动版本及确定性计数器。
- [ ] 只有等于当前已完整提交 ShardSequence 的 barrier 可以生成 snapshot；尚未应用、应用中或回退的序号均被拒绝，失败不产生可发布制品。
- [ ] 严格 decoder 验证 magic、长度、StateSchemaVersion、字段范围、集合唯一性、校验值和 CanonicalStateDigest；未知或较新版本、截断、位翻转和尾随数据均失败关闭，不猜测兼容。
- [ ] live state 与 snapshot restore 在同一 barrier 得到逐项相同的 AuthoritativeTradingState 和固定 CanonicalStateDigest；重复编码产生完全相同的字节。
