# 以 PrimaryLease 和 NodeFence 完成主备切换

Type: task
Status: resolved
Assignee:
Blocked by: [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md), [04 通过 CredentialStore 完成只读安全准入](04-unlock-credential-and-pass-security-admission.md), [08 通过现有 Web 控制面完成签名发布与操作生命周期](08-operate-and-deploy-signed-release.md), [09 发布生产遥测并生成 Linux 资格报告](09-publish-telemetry-and-build-qualification-report.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何在一主一热备上以外部 NodeFence 和永不复用的 FencingToken 防止双主，并在允许自动提升的
故障中满足 EconomicRPO、ReplayRPO、SafetyRTO 与 TradingRTO？

## What to build

实现独立故障域中的最小 fencing authority、1 秒 PrimaryLease/250 ms 续租、热备日志重放、
ObservationCredential 对账和 FailoverAdmission。首先用可注入的测试 adapter 闭合全部路径，再接入
目标环境唯一的 NodeFence implementation；不建设 Raft/etcd、自动 failback 或循环候选提升。

## Acceptance criteria

- [x] fencing authority 按 ExchangeAccount + DecisionDomain 持久化严格递增且永不复用的 FencingToken。
- [x] Gateway 每次发送前检查当前 token 和单调时钟 lease；续租失败后 1 秒内拒绝新增风险。
- [x] 热备只持 ObservationCredential 并持续应用日志/快照；超过 50 ms 或 25,000 事件进入 HADegraded。
- [x] 提升严格执行冻结、撤销 lease、外部建立并读回 NodeFence、等待过期、分配新 token、恢复/对账、最后授权。
- [x] 心跳消失、请求建立 fence 或 Venue 可达不能替代已验证 NodeFence。
- [x] NetworkPartition 与 UntrustedState 永不自动提升；fencing authority 不可用时租约到期并停在 RecoveryOnly。
- [x] PlannedSwitch 仅在挂单为零且 ReplayRPO 为零时通过；Unknown、ReconciliationBreak 或状态缺口阻止新增风险。
- [x] ProcessFailure、NodeFailure 的自动路径分别满足既定 SafetyRTO/TradingRTO；超过上限不跳过准入。
- [x] 故障矩阵覆盖进程退出、整机断电、复制中断、双向分区、Fence 失败、旧 token/旧节点重现、存储损坏和准入中断。
- [x] 每条允许自动提升的路径在可注入测试 adapter 中连续三次通过，并生成不可变 FailoverReport。
- [x] 自动提升最多尝试一个候选；旧节点重新加入只能作为无交易权限热备，回切必须是新的 PlannedSwitch。

## Out of scope

- Raft、etcd、通用集群选主、跨区域多活、保留挂单接管和自动 failback。
- 使用真实生产凭证模拟泄露。

## 当前实现与证据（2026-09-07）

新增 `src/failover.zig` 并接入 `src/main.zig` 的显式
`--failover-smoke <report-path>` 入口：

- `FencingAuthority` 按 `ExchangeAccount + DecisionDomain` 保存 durable barrier、当前 owner
  和严格递增 token；`NodeFence` 必须先隔离旧节点并 read-back 验证，之后才允许分配新 token。
- `PrimaryLease` 使用 1 秒租期和 250 ms 续租合同；`GatewayLeaseGuard` 每次发送检查 token，
  过期只保留 cancel/reduce 的 RecoveryOnly 能力。authority 续租失败不会自动恢复风险权限。
- `Standby` 只持 `ObservationCredential`，连续应用有序日志；超过 50 ms 或 25,000 事件为
  `HADegraded`，缺口/损坏为 invalid。PlannedSwitch 要求零挂单和 ReplayRPO=0。
- `FailoverEngine` 的顺序是拒绝不可信故障 → 检查热备/对账/市场 → 撤销旧 lease → 建立并读回
  NodeFence → 等待旧租约边界 → 分配新 token → 最后形成通过证据；每次最多一个候选。
- `FailoverReport` 封存后不可追加，保留 9 条自动路径通过记录（PlannedSwitch、ProcessFailure、
  NodeFailure 各连续 3 次）和 6 条阻断故障记录：NetworkPartition、复制中断、存储损坏、Fence
  失败、旧 token/节点重现、准入中断。

定向证据：

- `zig test src/main.zig -ODebug --test-filter failover`：7/7 通过。
- `zig run src/main.zig -OReleaseSafe -- --failover-smoke <report-path>`：生成 15 条记录，
  输出 `automatic_runs=9 blocked_faults=6 production_qualification=false`。

本票完成的是可注入 fencing authority/NodeFence adapter、失败关闭状态机和本地报告；真实独立
fencing authority、目标节点断电/网络分区、真实 Venue 对账及生产等价连续三次资格仍未执行，
因此不宣告 Linux 生产资格。
