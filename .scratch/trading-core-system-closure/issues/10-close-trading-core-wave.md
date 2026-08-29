# 形成可复现证据并关闭交易核心波次

Type: task
Status: closed
Assignee:
Blocked by: 09（已闭合）
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何由 SystemOwner 核验全部核心验收轨迹、权威所有权、稳定摘要、恢复与安全边界、README 复现入口及未资格事项，并在不混入 Adapter 扩展、生产部署或研究平台的前提下关闭交易核心系统地图？

## Acceptance

- [x] SystemOwner 可用 `tools/verify-core-wave.ps1` 在干净 Windows worktree 一次失败即停地复现全部离线证据。
- [x] Debug/ReleaseSafe、单分片五条轨迹、四分片、Python seam 与 Linux compile-only 全部通过。
- [x] 四分片 schema 1 冻结共享摘要，区分 coordinator/shard barrier，并输出实时发送数与重放发送能力。
- [x] coordinator 持久 tail 与非空 shard tail 覆盖成功、失败和途中再崩溃恢复，收敛到同一权威摘要。
- [x] README 记录唯一整波入口、实际稳定摘要和未资格事项；OKX Demo 仅由 `-DemoLive` 显式启用。
- [x] 未新增 Venue/OKX 协议能力，也未建生产部署、控制面或研究平台抽象。

## Evidence

- `zig test src/main.zig -ODebug`：111 项通过。
- `zig test src/main.zig -OReleaseSafe`：111 项通过。
- 四分片：coordinator barrier 17，shard barriers 23/25/21/21，`SharedSummary=e652a69fc3977ddb395edb6f0f2e6a7efc32d9e07d529c712aea33be6f09e6c2`。
- 副作用：`live_gateway_submissions=4`，`replay_send_capability=false`。
- Python：`strategy_host_product_acceptance=passed`。
- Python 容量五场景连续两次无重试通过，`gc_exception` 未再触发 `HostOutputTimeout`。
- 整波：`core_wave_acceptance=passed schema=1 mode=offline ... production_qualification=false`。
