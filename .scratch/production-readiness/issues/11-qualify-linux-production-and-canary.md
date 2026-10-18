# 取得 Linux 生产资格并完成小资金 Canary

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [05 在 Linux 闭合 OKX Demo 在线链路](05-qualify-okx-linux-online-chain.md), [06 在 Linux 闭合 Binance Testnet 在线链路](06-qualify-binance-linux-online-chain.md), [07 在 Linux 闭合 Bybit Testnet 在线链路](07-qualify-bybit-linux-online-chain.md), [08 通过现有 Web 控制面完成签名发布与操作生命周期](08-operate-and-deploy-signed-release.md), [09 发布生产遥测并生成 Linux 资格报告](09-publish-telemetry-and-build-qualification-report.md), [10 以 PrimaryLease 和 NodeFence 完成主备切换](10-fail-over-with-lease-and-node-fence.md), [main 安全与权威状态验收基线](../../main-safety-remediation/issues/12-rebuild-safety-acceptance.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何在目标 Linux 硬件、三家真实网络和最小真实资金范围内完成最后资格，且只有全部证据通过时
才把项目状态改为 ProductionQualified？

## What to build

冻结实际节点、网络、账户、凭证、Artifact、BenchmarkManifest 和风险上限；执行完整 Linux 原生
构建、持久化、密钥、Venue、生命周期、72 小时 soak、HA 和性能资格。随后先运行生产只读影子，
再由 SystemOwner 单独授权一个 Venue/账户/Instrument 的极低上限 Canary，最后封存证据并收口文档。

## Acceptance criteria

- [ ] [Linux 千单容量文件恢复验收](../../core-continuous-capacity/issues/11-verify-linux-file-recovery.md)及其前置任务已完成，且证据与本次 ReleaseArtifact 匹配；每分片 1,024 个存活订单、持续归档及恢复合同均通过，不以扩大数组或历史 Demo 结果替代。Linux 专项不等待 Windows 容量票或跨平台整波封存。
- [ ] 三家在线资格分别为 qualified；不存在 `not_run`、`failed`、`invalid` 或 Demo/Testnet 结果跨环境升级。
- [ ] Linux 原生 Debug/ReleaseSafe 回归、固定摘要、Python Host、四 shard、真实磁盘恢复和安全测试全部通过。
- [ ] 持久化 fault injection 与目标磁盘真实断电分三批连续通过，恢复状态和 ReplayRPO 符合合同。
- [ ] SteadyBalanced、SteadyHotShard、BurstRecovery、RecordedPeakReplay 各连续三次有效通过。
- [ ] 每个权威分布至少 1,000,000 样本；Core P99 ≤ 10 us/P99.9 ≤ 20 us/max ≤ 1 ms，InternalOrder P99 ≤ 50 us/P99.9 ≤ 100 us/max ≤ 5 ms。
- [ ] 正式日志、指标、风控、OMS、L2、约 100 个策略和四个 Python Host 在性能资格中全部开启；无硬失败或选择性丢弃运行。
- [ ] 三家连接、DurableStore、快照、热备、遥测和对账连续 soak 72 小时，无泄漏、持续队列增长、未解释 gap/Unknown/ReconciliationBreak/Suspense 增量。
- [ ] 生产 ObservationCredential 只读影子至少连续 7 天，账户、规则、时间、连接、RawIngress 和 semantic replay 持续闭合。
- [ ] 现有 Web 控制面在生产等价环境完成 OwnerSession、风险提示、全部控制命令、重复提交和未知结果显示验收；不存在独立控制面 CLI。
- [ ] SystemOwner 另行明确授权 Canary 的 Venue、账户、Instrument、资金与风险上限；本票或地图批准本身不构成授权。
- [ ] Canary 先证明 KillSwitch/Pause/恢复，再运行至少 72 小时；始终零未解释经济差异且可安全排空。
- [ ] ReleaseArtifact、QualificationReport、FailoverReport、OperatorRecord、运行手册和支持矩阵均以内容哈希封存。
- [ ] 只有全部条件满足且没有未关闭 P0/P1 缺陷时，README 和 map 才改为 `ProductionQualified`/`closed`。
- [ ] 当前 main 代码审查的安全修复波次已经关闭，且其最终验收 revision 与本次 ReleaseArtifact 完全一致。

## Out of scope

- Canary 后自动放大资金、Venue 或 Instrument；每次扩大必须成为新的资格范围和 SystemOwner 决策。
- 把一个节点、账户或 artifact 的资格推广到未经验证的环境。
