# 12: 重建可信验收基线并校正文档

Type: task
Status: active
Assignee:
Blocked by: [08](08-make-testnet-evidence-authoritative.md), [09](09-stabilize-strategy-host-capacity.md), [11](11-contract-legacy-core-input.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让项目完成度只由当前可重复执行的证据决定，并消除脚本、README、多 Venue 方案和历史 closure
声明之间的 schema、测试数、digest 与资格范围漂移？

## What to build

建立唯一失败即停的开发验收入口，从实际执行输出汇总 schema、测试数、barrier、发送次数和 digest，
而不是复制常量。完成后刷新仍作为当前入口的项目状态、架构范围和 tracker 索引；历史 ticket 保持原文，
通过新基线明确取代其已失真的当前状态声明。

## Blocked by

- [08: 使 Testnet 资格证据不可自行声明](08-make-testnet-evidence-authoritative.md)
- [09: 修复 StrategyHost 容量验收的不稳定性](09-stabilize-strategy-host-capacity.md)
- [11: 删除 CoreInput 包装与重复影子状态](11-contract-legacy-core-input.md)

## Acceptance

- [ ] 一条失败即停入口覆盖格式、Debug、ReleaseSafe、单 shard、四 shard、Python、三 Venue 离线契约和现有 Linux compile-only。
- [ ] schema、通过数量、coordinator/shard barrier、Gateway 发送次数和 CanonicalStateDigest 均从子验收的机器可读结果汇总，脚本不硬编码另一份结论。
- [ ] 成功轨迹固定当前期望摘要；语义变化未显式更新 schema/证据时必须失败，不能打印 passed。
- [ ] 默认运行不需要任何凭据、不访问 Demo/Testnet/生产网络；显式 live 入口的运行与未运行状态清楚分离。
- [ ] README、当前多 Venue 状态、开发入口和活动 tracker 与实际实现及证据一致，并明确历史 closure 仅供审计。
- [ ] 补齐仍作为导航入口的活动模块 map/Frontier；不批量改写历史 resolved/closed issue 内容。
- [ ] 本地图全部 ticket 具有实现证据后才将 map 状态改为 closed，并记录最终实际摘要与未资格化边界。

## Evidence

- `tools/verify-core-wave.ps1` now emits `core_wave_evidence=<JSON>` using actual child output for schema, Debug/ReleaseSafe counts, coordinator barrier/digest, live/replay send capability and Python status.
- Offline core wave passed with schema 2, 178 Debug tests, 178 ReleaseSafe tests, coordinator barrier 17, live submissions 4 and replay send capability false.
- This ticket remains active until ticket 11 reaches contract and current README/status documentation is refreshed together.
