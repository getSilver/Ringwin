# 03 离线验证记录

2026-10-21。任务：[03 增量盘口失效与重同步闭环](issues/03-depth-resynchronization.md)。基线 `ab315f9fe8bda1a4b26eb0378dac527a2673304f`，当前 main 分支；只提交本票差异，保留工作区其他删除项及未跟踪文件。

合同：[增量深度及重同步](../../docs/depth-resynchronization-contract.md)。所有权延续 ADR0001/0007/0014/0017，没有新增权威所有者、跨 shard 协调或发送权限。

## 最终命令及结果

环境：Windows PowerShell，Zig `0.17.0-dev.315+5b647b792`。全部为离线合成输入。

```powershell
zig test src/main.zig -OReleaseSafe --stack 536870912
python -m unittest discover -s python -p test_strategy_host_bridge.py
zig fmt --check src/adapters/okx/okx_market_feed.zig src/adapters/okx/okx_public_market.zig src/market/market_projection.zig src/model/canonical_event.zig src/persistence/canonical_event_codec.zig src/runtime/production_contract.zig src/testing/acceptance/core/four_shard_acceptance.zig src/testing/support/trading_shard_fixture.zig src/trading/trading_shard.zig
git diff --check
```

- 最终 ReleaseSafe **659/659**，0 跳过；[完整日志](03-final-full-suite.log)。
- Python 深度/Host bridge **5/5**，格式及 diff 检查通过。
- 当前格式：Canonical schema **15** / codec **13** / journal **42** / state **46** / registry **40**。Host type 7、event schema 1、704 bytes 不变。旧不兼容持久编码精确拒绝，不提供自动迁移。

## 公共行为及恢复证据

新增 6 项行为测试，其余 653 项为既有回归：

1. `03 depth updates delete levels and preserve Host evidence`：合成 OKX raw → ingest → MarketFeedAdapter.tryDrain → Projection → depthSnapshotInput。删除最优卖档、修改深档数量、保留第二档，买 6 的已知 tick-lots 成本为 610。新增更差价格不得扩大未经证明的覆盖，失败后 Host 返回 MarketGap。该测试在旧实现上因 MarketGap 失败，修复后通过。
2. `03 depth resynchronization capture replay agrees at every failure cut`：逐帧捕获与 raw replay 的规范事件一致，canonical codec 往返后盘口一致；连续 StrategyInputBatch 携带健康深度或 gap 期间空输入，IPC 验证及 payload 字节一致。覆盖重复一致、数量冲突、gap 中增量不能恢复、迟到快照、新快照恢复、再次缺口和畸形输入，不回填过去的决定。
3. `03 depth capacity unknown quantity and numeric overflow fail closed`：第九档、未知数量、decimal 溢出和倒序输出 gap，错误切点 raw replay 相同；截断快照后的增量要求新快照。
4. `03 canonical depth duplicates compare all evidence and rules changes revoke it`：非单位连续源序列、完整增量幂等、数量冲突保留旧内容但撤权、gap 不能由增量恢复、规则激活撤去旧深度。
5. `03 oversized captured frames revoke depth and replay before fresh recovery`：超过 1 MiB 的真实原字节先捕获，再绕过 JSON 解析产生 gap；raw replay 一致，更晚有效快照恢复 Host 深度。
6. `03 depth delta snapshot and stable tails preserve qualification at every cut`：九个稳定切点，逐次 snapshot + tail 及从初始状态完整稳定日志重放，CanonicalStateDigest 一致；健康 Host payload 一致，失效 Host 拒绝一致。包括正常增量、未知深档、冲突、恢复、再次缺口、错误可见时间、现有核心 i64 价格/数量范围及 u64 序列溢出。溢出候选的深度结构、前驱和 adapter identity 独立合法；每次范围拒绝前先恢复健康盘口，证明拒绝撤销已有资格。

第一次完整套件为 658 项，655 通过、3 失败：两项固定 schema 摘要漂移，以及新增 Host 测试遗漏 recordPublished。修正测试接缝调用；既有四分片和五条固定轨迹在经济断言、闭合、屏障及独立重放一致性检查通过后重新采集 schema-bound 常量。最终完整套件覆盖所有修复及新增超长输入用例，659/659 通过。

## Standards 审查

无阻塞发现或文档规则违规。适配器拥有 OKX 转换和盘口重建，核心只消费规范事实，公共测试覆盖适配器、Host 与持久接缝。建议清理的 BookTop 多余缓存字段已移除，BookState 只保留 ready/depth。少量局部 postimage 构造重复不构成阻塞问题。

## Spec 审查

初审 2 项：核心 i64 范围拒绝回滚保留旧健康深度；超长帧未输出 gap。均已修复并补回归；复审及最终测试调整后的复审无新增发现。Standards 0 项阻塞，Spec 0 项遗留。

## 资格边界

本票完成 I1 的连续盘口、失效、重同步与核心恢复子要求；不代表 I1 的整个跨所候选/策略决定链路、真实模型 checkpoint 或任务 10 综合验收通过。8 档及已知覆盖限制为明确首版合同，截断、超容量及未经证明的尾部失效会降低可用性。实际网络订阅/重连由现有 owner 管理；RawSink 无法提交证据的硬错误必须停止运行。其他 Venue、策略参数和模型、执行模式及任何 Demo/Testnet/生产资格不因此改变，没有部署或交易。
