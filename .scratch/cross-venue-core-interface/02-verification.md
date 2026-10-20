# 02 离线验证记录

2026-10-21。任务：[02 双边深度快照](issues/02-depth-snapshot.md)。

## 源码与范围

基于 `b7376ffc8641bd40b2f33ed2522b020a28d3ab39` 的已跟踪源码布局，在 `.scratch/build/depth02/commit-worktree/` 隔离本票差异。原工作区存在未提交的职责目录迁移及并发任务 04；本票提交保留 HEAD 的平铺源码路径，不将目录迁移或 IntentGroup 差异纳入。新模块在提交中为 `src/depth_snapshot.zig`，在迁移工作区为 `src/market/depth_snapshot.zig`，仅导入路径不同。

工作区原有 GLOSSARY.md 尚未跟踪，未将整份先行文档混入提交；本票的覆盖范围定义已更新到工作区，单行差异另保留为 [02-glossary.patch](02-glossary.patch)。合同独立记录同一语义。

环境：Windows，Zig `0.17.0-dev.315+5b647b792`，测试栈 536870912 bytes。版本为 Canonical schema 14 / codec 12 / journal 40 / state 44 / registry 38。所有测试均为离线合成输入，没有真实或 Demo 下单。

## 命令与结果

在隔离 worktree 执行：

```powershell
zig test src/main.zig -OReleaseSafe --stack 536870912
```

652 项执行完毕，650 通过、0 跳过、2 失败，日志：[isolated-full-releasesafe.log](../build/depth02/isolated-full-releasesafe.log)。两项失败均已修正：

1. 四分片固定摘要仍为旧 schema 的值。保留经济断言、逐 shard 状态及三条恢复路径相等检查后，更新 schema-bound 固定值为 `3e300e599dd3cff0360d7f21ee359d10781d18a11bf13babca14969b472e4e3e`。
2. 旧公共规范输入测试断言不完整快照拒绝后状态完全不变。现将该拒绝场景置于独立副本，验证旧盘口内容与经济状态保留、主品种及规范行情均进入 gap，后续成交轨迹保持原断言。

随后执行以下最终复验，包含显式 V2 原始输入：

```powershell
zig test src/main.zig -OReleaseSafe --test-filter test_0 --test-filter '02 ' --test-filter 'shared canonical adapter facts' --test-filter 'four-shard acceptance entry' --stack 536870912
python -m unittest discover -s python -p test_strategy_host_bridge.py
git diff --check
zig fmt --check src/canonical_event.zig src/depth_snapshot.zig src/market_projection.zig src/okx_market_feed.zig src/strategy_host_gateway.zig src/strategy_host_ipc.zig src/production_contract.zig src/trading_shard.zig src/canonical_event_codec.zig src/trading_shard_fixture.zig src/trading_shard_tests.zig src/four_shard_acceptance.zig
```

结果：受影响 Zig 用例 **5/5**，Python **5/5**，格式与 diff 检查通过。最终复验日志：[final-affected-releasesafe.log](../build/depth02/final-affected-releasesafe.log)。没有重新运行完整 652 项，不将上述结果记作一次全量 652/652 通过。

迁移工作区 Debug 定向恢复回归 **2/2**，覆盖 `applyStable → Host → snapshot + stable tails` 的健康输入、不完整快照失效、未知第三档数量及可见时间拒绝；日志：[recovery-final.log](../build/depth02/recovery-final.log)。

## 公共行为证据

- `OkxMarketFeed.ingest/replay → tryDrain → Projection → depthSnapshotInput → Gateway.encodeBatch → IPC.validateBatchAt`：双边多档、原始捕获重放、合法 ticks/lots、规则/Instrument 绑定、可见时间、覆盖与截断。
- V2：tick/lot 单位为 1，asks `100×1, 101×2`，买 3 支出 302；价格保护 100 时不形成虚假全量报价，可证单档买 1 支出 100。bids `99×1, 98×2`，卖 3 收入 295，价格保护 99 时不足。
- 买卖两侧、基础币/报价币费用、缺失与零数量、价格保护、容量溢出、非法尾部档位、不完整输入、迟到快照、旧 schema/codec 拒绝。
- `TradingShard.applyStable` 后完整稳定日志、快照、快照加健康及失效尾恢复：Host 字节与 CanonicalStateDigest 一致；拒绝后 gap 可重放，不泄漏旧健康深度。

## 审查与限制

code-review Standards 轴 0 项违规。Spec 轴发现的提前拒绝不完整快照仍暴露旧健康深度问题已修复，新增持久恢复回归并复审通过；最终测试断言修正及 V2 补充亦已复审。

本票完成 I1 的快照接缝与 V2，不代表 I1 候选/策略全链路、Python checkpoint 恢复、其他 Venue 多档、增量重同步或任何 Demo/Testnet/生产资格通过。L2 不提供 maker 队列位置、主动成交、条件执行或收益证据。旧持久格式无自动迁移；部署与历史迁移仍需单独验证。
