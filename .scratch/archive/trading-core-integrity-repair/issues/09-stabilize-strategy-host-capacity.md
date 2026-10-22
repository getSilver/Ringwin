# 09: 修复 StrategyHost 容量验收的不稳定性

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何修复 StrategyHost 慢容量场景在长批次运行中出现 HostInputStale 的根因，使验收能区分实现回归、
调度噪声和真实超时，而不放宽既定新鲜度及隔离合同？

## What to build

用最小确定轨迹复现当前长跑失败，明确批次发布时间、Host 消费时间和验证时间的单调时钟边界，并在
共享实现处修复错误的时效或背压演进。容量验收必须可重复，失败时报告足够定位的稳定证据；不得用
增大阈值、跳过慢场景或吞掉 HostInputStale 取得通过。

## Blocked by

None (can start immediately).

## Acceptance

- [ ] 有一条最小回归测试能在修复前稳定触发与长跑相同的 HostInputStale 根因。
- [ ] 修复后批次身份、HostSessionIdentity、StrategyCursor、新鲜度和背压边界仍满足现有安全合同。
- [ ] 慢或过期 Host 仍会被隔离并拒绝输出，不因容量修复获得宽松准入。
- [ ] Python StrategyHost 的完整阶段在当前支持的 Windows 开发环境连续多次得到一致结果。
- [ ] 失败输出包含场景、batch、单调年龄、预算和会话证据，自动入口仍然失败即停。

## Evidence

- Existing bounded monotonic validation remains at 50ms; no freshness threshold was widened.
- `python/verify_strategy_host.py` and the capacity stage passed with 4 hosts, 25 strategies/host and 1,400 batches per scenario; slow P99 remained below the contract and stale/full/rejected counts were zero.
- Slow, crash and recovery scenarios remain separately reported and fail-fast.
