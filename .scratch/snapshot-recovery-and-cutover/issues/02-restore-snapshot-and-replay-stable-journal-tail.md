# 02 — 从 snapshot 与稳定日志尾部确定性恢复

**What to build:** 从最近一份有效 AuthoritativeTradingState snapshot 恢复 TradingShard，并从 barrier 的下一 ShardSequence 开始按语义连续重放稳定日志直到目标位置；恢复构造没有 Venue 发送能力，因而无论重放多少次都不会重新发出订单、撤单或其他外部副作用。

**Blocked by:** 01 — 在 ShardSequence barrier 快照权威交易状态

**Status:** done

- [x] restore 要求日志首条待应用记录恰为 `snapshot barrier + 1`，并逐条验证 sequence、schema、CRC、输入身份和语义幂等；缺口、回退、冲突或中段损坏停止恢复并保持无新增风险权限。
- [x] 已 seal 的完整日志和明确识别的合法截断尾分别得到确定的 clean/truncated 结论；截断记录不部分可见，最后完整记录之后的状态与摘要可证明。
- [x] 同一历史从 Genesis 全量重放、较早 snapshot 加长日志、较新 snapshot 加短日志恢复后，得到相同 ShardSequence、AuthoritativeTradingState 和 CanonicalStateDigest。
- [x] 恢复使用不持有 VenueAdapter/dispatch 能力的 replay seam；历史 OrderCommand、cancel、DeRisk 或生命周期副作用只恢复权威结果，绝不重新发送。
- [x] snapshot 或日志验证失败时给出稳定恢复拒绝原因并进入 RecoveryOnly/失败关闭结果；不能回退到未明确选择和验证的状态继续交易。
