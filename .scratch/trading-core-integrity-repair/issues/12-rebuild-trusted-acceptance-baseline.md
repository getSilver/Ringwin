# 12: 重建可信验收基线并校正文档

Type: task
Status: resolved
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

- [x] 一条失败即停入口覆盖格式、Debug、ReleaseSafe、单 shard、四 shard、Python、三 Venue 离线契约和现有 Linux compile-only。
- [x] schema、通过数量、coordinator/shard barrier、Gateway 发送次数和 CanonicalStateDigest 均从子验收的机器可读结果汇总，脚本不硬编码另一份结论。
- [x] 成功轨迹固定当前期望摘要；语义变化未显式更新 schema/证据时必须失败，不能打印 passed。
- [x] 默认运行不需要任何凭据、不访问 Demo/Testnet/生产网络；显式 live 入口的运行与未运行状态清楚分离。
- [x] README、当前多 Venue 状态、开发入口和活动 tracker 与实际实现及证据一致，并明确历史 closure 仅供审计。
- [x] 补齐仍作为导航入口的活动模块 map/Frontier；不批量改写历史 resolved/closed issue 内容。
- [x] 本地图全部 ticket 具有实现证据后才将 map 状态改为 closed，并记录最终实际摘要与未资格化边界。

## Answer

12 号票已完成。`tools/verify-core-wave.ps1` 是唯一失败即停入口，直接消费子验收的机器可读输出，
汇总格式、测试数量、四 shard barrier/digest、coordinator digest、共享摘要、Gateway 副作用、
单 shard 轨迹、Python 场景和 Venue 离线契约证据。

## Evidence

- 执行命令：`tools\verify-core-wave.ps1`
- 结果：`core_wave_evidence.acceptance=passed`
- 环境：Zig `0.17.0-dev.315+5b647b792`，默认 `mode=offline`；未读取凭据，未访问 Demo/Testnet/生产网络。
- schema：`2`
- Debug/ReleaseSafe：各 `178/178`
- coordinator barrier：`17`
- shard barriers：`23/26/21/21`
- shard CanonicalStateDigest：
  `84c6f8b26b042e6323216db0f06ec4489a74e7e1f355f9107fd0e8656d062ab2`、
  `a21589dbdce1d216038a7f3fbc3cca85b9c8715eb50739bf2693af87786da6c2`、
  `80b4f54708b8809661b7f1890675cf3fcbb206262ca19b996b185a10c62945cc`、
  `0c58e2c1ede6059aa5642986df647d192b9771d21fd5ceabfdba31bf8f1dd627`
- coordinator digest：`7d0b0b6c2c078f39cbd3b0221983748eead747d9f5cd22e76b03eb2bcc97cdb0`
- shared summary：`e124735e7c33b86358e0a9fe23d9d1a51a86436627821b7cfc48ffbfc7f23476`
- Gateway：`live_gateway_submissions=4`，`replay_send_capability=false`
- 单 shard 轨迹摘要：`06fbeb256cfb02360c40668a8ccc34de0d4c8a532a1e0b1ebd4ff50b683c1048`、
  `b95c50d8d0b8c79b2b82f5191bb4ee031bac8369ebf4f838ff1bc80f86da4cdc`、
  `dded7fe60cc6693de322664fbf66b00ee05d177e990c3830644961a6ad514850`、
  `103e070525340114edb9fae1bd5c3b880f29c01b990f0fdf4ed3dd45adb938d4`、
  `06fbeb256cfb02360c40668a8ccc34de0d4c8a532a1e0b1ebd4ff50b683c1048`
- 基线锁定：`src/trading_shard_fixture.zig` 的既有轨迹恢复测试断言上述五条摘要；
  `src/four_shard_acceptance.zig` 断言 schema 2 的共享摘要，语义漂移会在脚本汇总前失败。
- Python：五个容量场景均输出实际样本结果，产品入口 `strategy_host_product_acceptance=passed`。
- 离线 Venue 契约：OKX、Binance、Bybit 均由 Debug 测试输出确认存在；SimulatedVenue 亦覆盖。
- 资格边界：OKX Demo 未运行时为 `not_run`；Binance/Bybit Testnet 为 `not_run`；生产资格为 `false`。
