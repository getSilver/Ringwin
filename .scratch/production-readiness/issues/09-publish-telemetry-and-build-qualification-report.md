# 发布生产遥测并生成 Linux 资格报告

Type: task
Status: resolved
Assignee:
Blocked by: [02 启动可安全排空的 Linux 生产进程链](02-run-linux-production-process-chain.md), [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何在不扰动 TradingShard 或泄漏高基数/敏感事实的前提下持续观察生产健康，并让每次 Linux
性能与故障资格生成不可挑选结果的 QualificationReport？

## What to build

实现每 shard 固定容量、本地单写者的 counter/histogram，以及异步 TelemetryPublish role；统一
资格 runner 生成 BenchmarkManifest 和不可变 QualificationReport，保留每次 Passed、Failed、
Invalid 运行及原始 bucket/健康证据。

## Acceptance criteria

- [x] CoreDecisionLatency、InternalOrderLatency、PythonDecisionLatency 和阶段延迟覆盖全部合格样本，无 coordinated omission。
- [x] 指标覆盖吞吐、队列、水位/年龄、Unknown、对账、账本、时钟、日志/热备游标、CPU/NUMA/IRQ、磁盘与 io_uring/transport 状态。
- [x] 热路径指标固定容量、无动态分配、阻塞锁或跨 shard 共享写；跨 shard 先合并 bucket 再计算分位数。
- [x] 常驻标签只有有界集合；订单、Instrument、StrategyInstance 和 client order id 不成为 metrics label。
- [x] TelemetryPublish 变慢或失败不占满交易通道；30 秒失明进入 ObservabilityDegraded，5 分钟失明禁止新增风险。
- [x] exporter 重启、缓冲耗尽、丢样、直方图溢出和 manifest 不匹配均有失败关闭或 Invalid 证据。
- [x] BenchmarkManifest 绑定 workload、数据/种子、规则、策略、artifact、节点、配置和观测开关。
- [x] QualificationReport 包含全部运行、原始 bucket、样本数、overflow、P50/P90/P99/P99.9/max、正确性和环境证据。
- [x] 观测开启/关闭 A/B 能计算既定开销预算，正式资格始终开启全部强制指标。
- [x] SimulatedVenue 上可一条命令执行小规模 smoke qualification，失败返回非零且不产生成功报告。

## Out of scope

- SIEM、无限 trace、全量订单导出到 metrics、研究数据管道和监控供应商抽象层。
- 在本票内宣告目标 Linux 性能已经合格。

## 当前实现与证据（2026-09-07）

新增 `src/telemetry_qualification.zig` 并接入 `src/main.zig` 的显式
`--qualification-smoke <report-path>` 入口：

- 每 shard 的 `Telemetry` 只含固定容量 histogram/counter；`observe` 不分配、不加锁、
  不跨 shard 写。聚合阶段才合并四 shard bucket，再计算 P50/P90/P99/P99.9/max。
- `Publisher` 是固定容量 8 的非阻塞生产者队列，`TelemetryPublish` 角色消费；满队列、
  exporter 失败、重启、丢样和直方图 overflow 都保留为证据。30 秒后为 `degraded`，
  5 分钟后为 `risk_revoked`，时钟倒退失败关闭。
- `BenchmarkManifest` 绑定 workload、seed、rules、strategy、artifact、节点基线、配置和
  observation 开关；`QualificationReport` 封存后拒绝追加，并保留 Passed/Failed/Invalid
  运行、原始 bucket、计数器、正确性、环境、publisher 与观测 A/B 预算证据。
- smoke runner 实际启动 `SimulatedVenue`，执行四 shard 核心验收后才原子写报告；任何前置
  错误在写入前返回非零，因此不会产生成功报告。报告明确写出
  `production_qualification=false`，不升级 OKX/Binance/Bybit 资格。

定向证据：

- `zig test src/main.zig -ODebug --test-filter telemetry`：7/7 通过。
- `zig test src/main.zig -OReleaseSafe --test-filter qualification`：12/12 通过。
- `zig build-exe src/main.zig -target x86_64-linux -OReleaseSafe` 通过；WSL 原生 ELF
  `--qualification-smoke /tmp/ringwin-qualification-report.json` 返回 0，报告存在且
  `"conclusion":"passed"`。

本票完成的是遥测/资格报告的本地实现和 Linux smoke 入口，不等价于目标 Linux 节点性能、
72 小时 soak、磁盘断电、真实 exporter 或生产资格；这些仍必须在目标节点取得独立证据。
