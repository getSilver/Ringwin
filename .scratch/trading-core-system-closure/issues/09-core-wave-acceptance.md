# 形成核心成功与故障整波自动验收

Type: task
Status: closed
Assignee:
Blocked by: 08（已由 `7977ed2` 闭合）
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何形成一条失败即停的自动入口，以固定且版本化轨迹覆盖核心成功路径、市场/策略/订单/风险/账务/操作/恢复故障、Python seam、SimulatedVenue、四分片和显式启用的既有 OKX Demo 事实，并证明实时、重启和语义重放等价且历史路径永不重发副作用？

## Acceptance

- [x] `tools/verify-core-wave.ps1` 依次执行格式、Debug/ReleaseSafe、单分片、四分片、Python seam 与 Linux compile-only，任一步失败立即停止。
- [x] 单分片五条 v1 轨迹与四分片 schema 1 `SharedSummary` 均冻结预期 digest，语义漂移不能输出通过。
- [x] 四分片证据分别输出 coordinator barrier 与各 shard barrier，不混淆权威边界。
- [x] 四分片覆盖协调器持久 tail、非空 shard tail、成功/失败/途中再崩溃恢复，并证明 live、全量重放与 snapshot-tail 摘要等价。
- [x] 恢复类型不持有 Gateway/发送能力，恢复后的 OMS outbox 为空；验收同时固定 live Gateway submission 数量。
- [x] OKX Demo 事实默认禁用，仅在 SystemOwner 显式传入 `-DemoLive` 时复用既有安全验收入口。

## Evidence

- `zig test src/main.zig -ODebug`：111 项通过。
- `zig test src/main.zig -OReleaseSafe`：111 项通过。
- `python python/verify_strategy_host.py`：14 阶段通过。
- `tools/verify-core-wave.ps1`：输出 `core_wave_acceptance=passed schema=1 mode=offline ...`。
