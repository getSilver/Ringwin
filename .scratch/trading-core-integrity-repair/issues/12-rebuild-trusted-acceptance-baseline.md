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
- acceptance schema：`2`；journal/state schema：`7`
- Debug/ReleaseSafe：各 `185/185`
- coordinator barrier：`17`
- shard barriers：`23/26/21/21`
- shard CanonicalStateDigest：
  `0d3c0e10ab2b913cc5b195060c2387bbef45466f88a3a0e4d2bc97f197ee4196`、
  `e162eef88bc728ccd00b6177fe24d6019115ca68513f9fe17d2da71547109680`、
  `eb96cfadb162c467e729457aafdd790a09f07eb2db9e690cbcba92619a4501f8`、
  `435f277a1092bab7cf9711f392366e33c9350daaf1571412e3975118dd8da058`
- coordinator digest：`7d0b0b6c2c078f39cbd3b0221983748eead747d9f5cd22e76b03eb2bcc97cdb0`
- shared summary：`aa0df1c6767e47c53c450d15d467c9624e92b9025e7a3c4ca8fa5ebe78d1bb3d`
- Gateway：`gateway_adapter_submissions=5`；四分片 ownership：`owned_command_count=4`；
  `replay_send_capability=false`。两种计数不再混称为 live submissions。
- 单 shard 轨迹摘要：`b8aa3c906ec10468b87630fc593ba1068ee4e6a9ea770202b3b031433afed100`、
  `8818cea074c195271629d21c4c90ac25a76b0d2747b343bed18690e3ee903a8b`、
  `cd327b5bf139b2b4ad836b51dacd2c52475a87e47b4a95599a3e1e668c07845c`、
  `d4788166cdeb56162012c8187c8c358a7f3ac8edb01931cbad0e6ffdcfa9ee9c`、
  `b8aa3c906ec10468b87630fc593ba1068ee4e6a9ea770202b3b031433afed100`
- 基线锁定：`src/trading_shard_fixture.zig` 的既有轨迹恢复测试断言上述五条摘要；
  `src/four_shard_acceptance.zig` 断言 acceptance schema 2 的共享摘要，语义漂移会在脚本汇总前失败。
- Python：五个容量场景均输出实际样本结果，产品入口 `strategy_host_product_acceptance=passed`。
- 离线 Venue 契约：OKX、Binance、Bybit 均由 Debug 测试输出确认存在；SimulatedVenue 亦覆盖。
- 资格边界：OKX Demo 未运行时为 `not_run`；Binance/Bybit Testnet 为 `not_run`；生产资格为 `false`。
