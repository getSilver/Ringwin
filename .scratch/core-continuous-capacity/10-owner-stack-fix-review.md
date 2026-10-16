# 10 Owner 冷查证栈修复与空尾轮转复核

2026-10-16，实施者复核。本记录核对两处生产函数拆分、真实失败链及后续夹具修正，不替代独立 Standards/Spec 审查或最终资格验收。本次复核仅新增此记录，未改源码、六个 producer 或既有数据集，也未启动编译。

当前冻结输入为 [final-v3 source manifest](10-final-v3-source-manifest.json)：114 份源码，`f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42`。已逐项核对以下实际文件哈希与该清单一致：

| 文件 | SHA256 |
| --- | --- |
| `src/demo_authority.zig` | `678bdc5f9a7bf4fdf8e2ab78638749ed623bcad9281edc9da13bc8f6a02bf6b7` |
| `src/trading_shard.zig` | `8e67bd0dedf0ab02ae96ae947ff72b9ed1de755d6dbfd6aef4bf4e4b608b6e2d` |
| `src/windows_capacity_shared.zig` | `97e8d2cc45c8a909042387becc7125523f02fb5ccf7df6d7563a39e7e404195e` |
| `src/main.zig` | `6c39eb88718a15fb9cfe8c51f3af34e736cf2019c52960997078d957cd4d488f` |

## 两处生产拆分保持原事务与回滚

`Owner.apply` 先执行原来的 checkpoint/archive/history 准入、冷候选 staging、查证递归及 private-boundary 前置校验，再进入 private `noinline applyCommittedCandidate`。后者完整保留原候选复制、`applyStableOnCandidate`、错误事实处理、journal 追加、durable commit 及最后发布；未新增 heap 分配、放宽查证或移动控制标志的作用域。这样外层冷查证 staging 不再提前预留一份未使用的完整 TradingShard 候选栈帧。

`TradingShard.confirmPendingReplacement` 完整保留 `replacementIntent`、查找失败时 discard、无 replacement 返回及 `blocksNewSend` 的 discard/返回。只有实际存在且允许继续的 replacement 才进入 private `noinline qualifyAndConfirmReplacement`；候选资格检查、拒绝分类、reservation/authority 事实、确认和复制发布均保留原样。生产改动合计 Owner 新增 7 行、Core 新增 6 行，未改变持久格式或规范摘要合同。

尤其没有把 `finalizeHistoryCandidate` 的 `applyVenue` 回滚基准替换成 outer previous：查证完成时已经释放 deferred、清除 pending 并追加 proof 事实，原始输入前的 savepoint 与外层 committed state 不同。直接别名替换会改变经济拒绝及 latch/pending 恢复语义；本次未采用该做法。

## 实际失败没有合并成通过

以下均使用真实 `src/main.zig` 应用入口、实际 PE 64 MiB stack 和新建的独立文件数据集；原 producer、旧产物及失败数据没有被覆盖。名字含 `green` 的开发 prefix 仍以实际退出状态为准。

| 源码身份 | 证据 | 实际结果 |
| --- | --- | --- |
| `73532d4a…b31492bce` | [原始重复红](10-owner-stack-red-v1/advance-02.result.json)、[stderr](10-owner-stack-red-v1/advance-02.stderr.log) | `advance-02` exit 3；外层 `Owner.apply`、proof apply 及 `handleOmsGroup` 的大候选帧叠加，栈溢出。此前 seed、首轮及其恢复通过不证明后续冷路径安全。 |
| `ab45808f…8f34f48` | [仅拆 Owner 后](10-owner-stack-green-v1/advance-02.result.json)、[stderr](10-owner-stack-green-v1/advance-02.stderr.log)、[冻结输入](10-owner-stack-first-fix-frozen.json) | `advance-02` 仍 exit 3；已越过先前 place 路径，转到 cold canonical report 的 `confirmPendingReplacement`。其 replacement 实际为空，原函数仍预留第三份大候选帧。 |
| `c29cba9a…c247885` | [两处拆分后](10-owner-stack-green-v2/advance-02.result.json)、[stderr](10-owner-stack-green-v2/advance-02.stderr.log)、[冻结输入](10-owner-stack-second-fix-frozen.json) | 原栈溢出消失，但该次十轮编排仍失败：exit 1，`InvalidArchiveDescriptor`。不能将它写成完整十轮绿。 |

两处拆分后的 [asm/PE 布局记录](10-owner-stack-green-v2-layout.json) 绑定应用 `b1ab4ecf349fe54b01c3bfed7250336177f6d9e7a74a8e4e5a9c4987c7f62d3c`，PE stack reserve 为 `67,108,864` B：

| 函数 | 静态 frame 字节 |
| --- | ---: |
| `Owner.apply` | 128,896 |
| `Owner.applyCommittedCandidate` | 22,860,536 |
| `confirmPendingReplacement` | 424 |
| `qualifyAndConfirmReplacement` | 22,714,328 |
| `applyVenue` | 22,662,984 |

这是编译后的单函数静态预留，不是线程实际峰值栈实测。没有提高应用栈。

## Coordinator 空尾夹具修正

`InvalidArchiveDescriptor` 的独立最小公共 File 回归先产生一次真正变化的 summary，然后重开并再次提交相同观察：[exact red](10-shared-nochange-exact-red.result.json)、[完整调用链](10-shared-nochange-exact-red.log)。实际 exit 1，路径为 `verify -> CoordinatorOwner.checkpoint -> Store.rotate -> receiptFromPage`；零 records 的 archive descriptor 被现有校验拒绝。该红的源码为 `39faa110…8c0c3e`，包含新回归，不能冒充原 c29 的相同源码身份。

当前 `windows_capacity_shared.zig:54-65` 在恢复后的公开发布循环前记录 `before_publication = owner.sequence`，仅当公开 `CoordinatorOwner.apply` 实际推进序号后才 checkpoint。这与原合同一致：

- 未变化的观察不会调用 publish/checkpoint，不伪造新身份、不重置序号，也不把空 archive 合法化；既有 checkpoint 或合法已提交尾部继续可恢复。
- 真正变化仍用原公共 publish_summary 事件持久提交，再 checkpoint；没有因避免空尾而跳过变化。
- `publish_updates=false` 的 recover 路径不进入该发布/检查点分支。恢复后仍要求 `recovery_only`，未重新分配 lease 或恢复发送权限；原 lease used 必须与实际 Owner 占用相等，否则失败关闭。
- `Store`、`CoordinatorOwner` 和 Core 的生产校验未为该夹具问题修改。

[green result](10-shared-nochange-green.result.json) 绑定最终 f1e1a54a 源码且 source/producer drift 均为 0，[日志](10-shared-nochange-green.log) 实际为 2/2：`main.test_0` 和 shared 回归。回归验证首次变化、相同观察深度相等、重开相等、再次真实变化的 barrier 推进及再次重开相等。`main.zig:42,263` 显式引用该模块，避免只从运行时 helper 懒导入而漏掉测试发现。

## 覆盖边界

[现有公共 CCC 回归](10-owner-stack-ccc-debug.result.json)、[日志](10-owner-stack-ccc-debug.log) 在 c29 源码下 Debug 1/1 通过，保留真实 successor/predecessor 生命周期、归档及冷身份零重发行为；该单测使用 256 MiB stack，只证明对应语义回归，不能当作 CCC 所有冷路径的 64 MiB 证明。非空 replacement 的 cold report 组合仍可能同时需要多份大候选；本票未取得通用全路径栈或线程实际峰值资格。

截至本记录，final-v3 的真实 64 MiB 十轮/500 观察和最终完整套件正在独立新管线中执行；这里不预写其结果。最终通过必须由该管线的终态、文件哈希只读比较、实际输入/归档/恢复及 source/artifact 身份证明。旧 v1 的完整套件绿、局部回归绿和静态 frame 数据均不能替代它；也不授予千单、压力、资源预算、断电、外部 NodeFence 或 Windows 生产资格。
