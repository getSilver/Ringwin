# 05 性能优化历史记录

以下记录保留当时诊断与执行状态。当前功能源码85c00368已完成Debug/ReleaseSafe各538/538与两项离线CLI；最新用户要求取消千单和容量压力测试。最终结果以[05证据](05-evidence.md)和[当前审查](05-optimization-review.md)为准。

用户要求先停止测试、完成优化，再重新测试。整体 12 项目标保持不变。

## 已确认的热点

矩阵进程 PID 6944 的 1,000 次本地指令地址采样：

- `memcpyFast` 55.3%，`memset` 30%，名为 `round` 的叶函数 10.1%；仅凭这个名字不能确定其具体调用方。
- 采样持续 22.38 秒，目标进程 CPU 增量 22.17 秒。
- 数据见 `05-native-cpu-6944.json`。这是叶函数样本占比，没有完整调用栈，不能当作吞吐、延迟或生产资格。

源码中每次输入存在 Owner → applyStable → TradingShard.apply → Core/Venue 的多层完整候选复制。TradingShard 为 22,097,632 字节，OMS 为 15,488,768 字节。矩阵每累计 4 次维护操作执行 Owner 与 Gateway 检查点；30 秒归档边界使用逻辑时间推进，没有逐单实际等待。

## 已落盘，尚未运行验证

1. Owner 复用已拥有的私有候选，绕过 stable/apply 的两层重复候选。普通公共接口仍保留事务包装。每输入少四次 Core 复制，约 88 MB。保留错误事实发布标记、原时钟、完整输入摘要、journal rollback 和 Store commit 后发布。
2. MemoryAdapter 大快照轮换 current/previous 的独立 owned buffer，避免先把 current 完整复制到 previous。保留 inline 路径、两个可恢复版本和失败关闭；允许输入借用旧缓存而不产生重叠 memcpy。
3. Owner 增加调用方 scratch 检查点入口，矩阵每个 Cycle 独立拥有并复用缓冲区。scratch 不进入核心状态、摘要或快照。检查点频率不变。
4. 已发布检查点先验证屏障和状态摘要，只在需要新发布时分配并编码。正常路径仍按编码、seal、publish、rotate、receipt 的顺序执行。

5. 快照编码直接借用原状态，对未使用数组编码一次确定性默认行并重复其字节，避免先复制约 22 MB 再清零。保留原 canonicalizer 作为测试对照，快照格式与 CanonicalStateDigest 合同不变。
6. 只读审查发现 inline current 保存时可能覆盖或释放借用的 previous 输入。仅在该别名路径临时保存输入，并覆盖 inline 与 overflow 两种 previous。

## 测试与状态

会话 85289、58411、49571 均按用户要求终止，退出码 1；这不构成验收通过。进程检查确认没有活动 `test.exe`。旧完整 Debug 有第 375 项旧来源接口失败；矩阵仅完成第一分片种单及第二分片部分终态种单。新的来源绑定回归 71609 已在停止指令之前通过。

优化实现完成后已按用户“再测试”要求恢复针对性回归。ReleaseSafe 7/7 通过（包含 main 导入测试）：快照字节与原 canonicalizer 一致且原状态不变；公共与 owned stable 路径的提交、重复、权威拒绝及 journal rollback 一致；overflow/inline 轮换、借用输入和分配失败；scratch 尺寸与 Owner 别名拒绝。日志为 `05-optimization-regressions-releasesafe.log`。格式与 diff 检查通过。完整静态编译 69214 已通过；后续新增回归与别名修复另行编译。

四分片真实 Owner 容量矩阵已重新启动，日志 `05-owner-capacity-optimized-releasesafe.log`；未完成前不能声明通过或整个矩阵的加速倍数。快照微基准使用相同 684,774 字节快照，各执行三次且验证字节一致：旧 copy/canonicalize/encode 共 83,375 微秒，新借用编码共 31,801 微秒，约 2.62 倍。仅为这一小状态、这一次 ReleaseSafe 运行的局部对比；矩阵启动与编译并发可能影响耗时，不能替代完整矩阵或生产资源验收。

最终完整静态编译 69908 已通过；包含微基准的优化回归再次 7/7 通过。后续只读审查确认借用 previous 修复没有剩余具体阻碍。当前 89 文件源码身份见 `05-optimization-source-manifest.json`（`dd86f518fa674ddffbae6edd8dc57a6398f46e7e7905fb9d2c8618d66435e307`）。

优化后矩阵 PID 9404 确认存活，第一分片已种下 512 个终态订单。其第一分片种单期间另取 1,000 个叶样本：`memcpyFast` 66.6%、`memset` 23.3%、`round` 6.7%；21.83 秒采样内 CPU 增量 21.33 秒，见 `05-native-cpu-9404.json`。剩余内存开销仍然很大，不能由样本占比推断整个矩阵变快或变慢。Core/Venue 和 OMS 的内部事务回滚候选仍保留；生产资源合同（特别是 64 KiB 状态复制与 2 MiB 线程栈）尚未满足，仍属于 09 必须闭合的范围。

子代理因指定模型暂时不可用退出，Root 接管全部优化文件。第 05 项保持 in-progress，不授予资源、性能或平台资格。

## 第二轮：复用 Core/Venue 回滚候选

第一轮后的矩阵仍以复制/清零为主要热点。在第一分片完成 1,024 个终态后再次终止会话 77519（退出码 1），确认没有活动测试，继续优化。这个中断结果不是容量通过。

外部 owned candidate 直接执行 Core/Venue 输入，正常成功路径不再创建、发布另一份完整 Core；普通拒绝恢复外部 previous，指定权威失败仍发布原故障分支，经济失败先恢复 previous 再锁存。嵌套冷证明的内部事务仍有独立候选。正常输入再减少两次 Core 复制，约 44 MB；不能以减少的字节推断完整吞吐。

第二轮优化回归 ReleaseSafe 8/8 通过，含 legacy nested 与 owned Core/Venue 的输入、普通拒绝、schema 拒绝、市场故障与执行报告拒绝对照。日志 `05-optimization-second-regressions-releasesafe.log`。同一小快照三次编码另得旧 53,157 微秒、新 20,627 微秒，仍仅是局部样本。

Standards 审查另发现崩溃于 Core A 已归档、Gateway A 尚未 append 后，直接归档 B 会覆盖 A 的恢复回执。Owner 现在先完成前一 Gateway 归档，再构造、发布 B；同根检查已提交连续尾部并完成 sealed checkpoint，失败先关闭 Owner。两订单公共成功/前置失败回归 ReleaseSafe 2/2 通过，见 `05-predecessor-recovery-releasesafe.log`。两个审查轴复查均未确认剩余 P1/P2。

当前 89 文件身份为 `be15d0da3e1f4a827304192b97e91d7f39a0fe6675ae3802141b04333db72665`，见 `05-optimization-second-source-manifest.json`；取代第一轮源码身份用于后续验收。完整当前 Debug/ReleaseSafe 正在编译，旧完整测试程序和中断矩阵不能证明这一版本通过。

当前完整 Debug 编译 13884 已退出 0，测试程序启动为会话 99212 / PID 11060，计划 531 项，日志 `05-optimized-second-full-debug.log`。完整 ReleaseSafe 编译仍是会话 12064。测试完成前不授予完整验收或资源资格。

完整 ReleaseSafe 编译 12064 已退出 0，尚未执行。应用 ReleaseSafe 构建 8860 已退出 0，产物 SHA-256 为 `19e9b97e189f0d6c947bdee5918535b44b6be8475131a52f4f395e63d433985b`，111,207,424 字节，身份记录 `05-optimized-second-build-artifact.json`。当前完整 Debug 已通过前 64 项且 PID 11060 确认存活；这个进度仍不代表完整通过。

## Windows 调用入口：当前已停止测试并修复

第二轮完整 Debug 实际通过前 121/531 后停止（会话 99212 退出 1），目前没有测试进程。中断原因是额外纯模拟 CLI `--windows-chain-test` 失败：`runRole` 函数入口栈溢出，随后控制器 `RolePipeTimeout`。日志 `05-optimized-second-windows-simulation-chain.log`，PE 头验证该程序确实预留 268,435,456 字节栈。不能增加测试栈绕过这个缺口。

GPT 6.1 Sol / medium 子代理修复 `windows_verification_runtime.zig`：七个 32 MiB 栈快照缓冲区改为一个角色持有的堆缓冲区；恢复目的地使用堆内存和 Into API；Gateway 使用计数器初始化，避免 75 MiB 聚合初始化临时值。Root 在共享 Owner 提供 `bootstrapInto`，原 `bootstrap` 委托其执行，保留 virgin stream/gate 校验及失败目的地关闭。生命周期、摘要/屏障检查和所有角色转换保留。只读 Standards 复查未发现具体剩余缺陷。

当前只执行静态编译和栈帧诊断（会话 33456），未恢复测试。构建及运行结果要对应这一新版本，第二轮 be15 身份、旧构建和部分 Debug 不证明当前调用入口可运行。≤2 MiB 生产线程栈及≤16 KiB单帧仍未资格化。

堆缓冲版本编译 33456 已退出 0。汇编测得 `runRole` 栈帧 5,160,664 字节（约 4.9 MiB），日志 `05-windows-role-heap-layout.json`；最大控制器 `runIntegration` 帧仍为 167,092,904 字节，不能声明生产栈安全。纯模拟重跑已启动五个角色，入口栈溢出消失，但随后在 engine exercise 因 `InvalidOrderArchiveTime` 失败（14355 退出 1），见 `05-windows-role-heap-chain.log`。

根因是 SimulatedVenue 的接收时间固定为 1 纳秒，早于真实提交的模拟订单创建时间。新增 adapter-owned `receipt_times`（默认保持 1 不改变旧场景），Windows 模拟按提交订单的 creation UTC + 1 ms 设置接收 UTC，并使用实际模拟 dispatch 的 monotonic time；核心时间校验保留，runner 不改写返回事件。公开 start/send/drain 回归核对三个 request kind 的全部事件时钟，ReleaseSafe 2/2 通过；共享 bootstrapInto 回归亦 2/2。只读复查确认时间为事件产生时的 owned copy，重设时钟不会改变已排队事件。

最新进程链程序正在编译（67766），等待这一版本的完整 CLI 运行结果。旧失败日志与部分完整测试仅是诊断，05 保持 in-progress。

## 精确恢复与控制器栈

修正接收时钟后，旧手工 replay 输入列表缺少 `sealBootstrap` 实际提交的检查点回执，产生 `ReplayDigestMismatch`。改为从真实 Store 重放后，诊断显示已完整恢复到 barrier=committed=45，但活动日志尚无 footer，扫描状态为 `truncated_tail`；`journal.Reader.next` 对完整的未封口活动尾部也返回这一状态，不能要求它等同于 sealed segment 的 `clean`。调用入口现复用 `Owner.recoverInto` 的实际物理前缀验证、关闭及 checkpoint_pending 检查，随后将恢复 Core 交给没有 Gateway 的 ReplayTradingShard 包装器，再比较完整摘要。

该版本纯离线链已通过 engine 的 Python Host、提交、模拟 Fill 和 replay 摘要核对，也继续走过离线 OKX Host 与私有事件注入；随后在控制器重新打开 Store、调用旧 by-value Owner.recover 处栈溢出（59461 退出 3），见 `05-windows-role-owner-recovery-chain.log`。当前正在迁移控制器及相关恢复 helper 的大对象，不提高 256 MiB 测试栈。

离线 fixture CLI 已改为五个堆 LiveRun、现有 Into 轨迹和指针验证/摘要，`05-offline-fixture-heap-releasesafe.log` 实际退出 0，五个原 V11 golden 全部保持。静态 `main` 帧从 423,326,808 降到 22,805,736 字节，见 `05-offline-fixture-heap-frame.json`；仍不是生产单帧/线程栈资格。

控制器迁移已落盘：runIntegration 两份独立快照缓冲区、恢复 Owner 和恢复 Store 均使用堆存储；private restart 使用两份独立恢复 Core，原状态不会随复用缓冲区被覆盖；private startup 改为 allocator + restoreSnapshotInto，三个调用点同步更新。所有原状态、摘要、故障、恢复屏障和零发送断言保留。两个指定模型子代理实现这些 caller-only 调整，Standards 只读复查未发现具体剩余问题。

最新构建是会话 48302（`05-windows-controller-heap-build.log`），确认编译器 PID 12524 存活；完成后再重跑纯离线链。没有活动测试或矩阵进程，未授予完整套件、容量、资源或平台资格。

## 调用入口修复验证完成，恢复完整验收

控制器 heap 构建 48302 退出 0，其运行 92633 已越过所有第一代处理和磁盘恢复，在第二代执行角色因 `MissingDispatchIdentity` 失败。原因是旧 private recovery 仅扫描 Unknown，而 accepted 发送结果现在也独立持久化。恢复现通过已恢复 Core 的 place command + `Gateway.acceptedClientOrderIdFromShard` 查找已接受身份，与 Unknown 身份交叉核对；没有新建 ClientOrderId 或发送命令。只读复查未发现具体剩余问题。

最新构建 14228 和纯离线链 94221 均退出 0，日志 `05-windows-accepted-recovery-chain.log`：五角色、Native Python/Fill/replay、离线 OKX Host/private、磁盘恢复、快照传递、private startup/restart，以及异常快照/权限/世代拒绝断言通过。末尾资格报告仍明确 blocked/production_qualification=false：这是功能断言成功，不授予 Windows 平台、资源、在线或生产资格。

静态帧（accepted lookup 前、控制器布局未再改）见 `05-windows-controller-heap-frame.json`：runIntegration 244,856 字节；verifyPrivateProcessRestart 310,680；recoverPrivateStartup 16,600；runRole 5,160,664。与原控制器 167,092,904 字节及 private restart 133,010,776 字节相比大幅降低，但仍不满足完整生产帧/线程栈合同。

89 文件当前身份 `6b6864ee33bfbd764128bd79bd48578efe32a104d9df51467990147c9d98e814`，见 `05-caller-heap-source-manifest.json`，取代先前 be15 用于完整验收。完整 ReleaseSafe 编译 29314、Debug 编译 77429 已启动；完成后执行当前程序，旧 121/531 中断结果不替代它们。

两种完整测试程序编译均退出 0。当前完整 ReleaseSafe 会话 80050、日志 `05-caller-heap-full-releasesafe-test.log`，仍在运行；Debug 尚未执行。应用 ReleaseSafe 构建 89044 退出 0，当前产物 66,640,896 字节，SHA-256 `c3d0715d2266fab1a0fa5bfb1876bec9e582b8ab4f39057da7e8e9eef6d137c5`，见 `05-caller-heap-build-artifact.json`。最终 Spec/Standards 两轴只读复查均未确认剩余具体 P1/P2，见审查记录。以上不能代替完整套件和四 Owner 容量实际退出结果，05 保持 in-progress。

## 第三轮：OMS 自有事务的整状态复制

### 当前冻结程序的短时采样（2026-10-13）

当前源码3c1d7b91的两套完整执行61799/15035仍存活。使用已有 native
suspend/read/resume 采样器的限定路径副本，对PID4328/5396各150个指令点采样，
不写业务内存、不更改源码或重启测试。Debug样本round33.33%、rotr31.33%、
memcpyFast/memset各14.67%；ReleaseSafe round51.33%、memcpyFast22.67%、
memset17.33%。原始证据05-native-cpu-4328.json/05-native-cpu-5396.json。
这是短时leaf分布，不能单凭符号定位具体上层调用或换算整体吞吐/提速。
ReleaseSafe后续实际输出stream1100 seeded_terminal=3584，尚无全部四分片
同时驻留/十轮/恢复的最终结果。两套现有执行继续运行，源码保持冻结。

### 当前状态覆盖说明（2026-10-13）

第三轮完整 Debug `12056` 与 ReleaseSafe `89413` 都已主动停止，退出 -1。
两者实际通过前 414/534 项；ReleaseSafe 在 case415 通过四分片同时各保留
1,024 live 和 3,600 terminal 的断言，但初始归档、十轮替换和最终恢复未完成。
Debug 仍在首分片 seed 阶段。不能把旧进程状态或初始驻留断言当作完整矩阵通过。

停止原因是当前源码发现确定的平方热点：`order_history_batch.build` 对原
intent_history 每一项调用 `containsIntent` 扫描释放后的历史表，初始约
8,224 项时仅此一步每单约 3,380 万次身份比较。OMS `commitOrderArchive`
使用稳定顺序删除，可采用两个活动前缀的双游标差集保留相同归档身份集合，
避免此重复扫描。GPT 6.1 Sol / medium 正在仅修改 builder 并验证公开行为；
该变更不减少负载、归档条目、故障边界或检查点频率。新身份及完整验证待完成。

第四轮实际结果：builder 主循环已采用完整 strategy+sequence 的双游标，
组内保留查找仍在，归档编码顺序不变。新增公开回归在 place/submitted/accepted、
cancel/安全终态的合法生命周期下形成五条交错意图，准确导出目标两条，
且原热表不变。新夹具前两次因缺 accepted/未及时闭合 PendingCancel 失败，
已纠正夹具，不改业务准入；最终 Debug 18434 与 ReleaseSafe 44782 各 7/7，退出 0。
独立 Spec 再读最终夹具未发现具体 P1/P2，fmt/diff 通过。

新 89 文件身份 `8f6f10c4e441b2692cd2fdb0f184bccae0fe3c13bf546b907e3415ac49f9b2ca`，
相对第三轮仅 `src/order_history_batch.zig` 改变。完整 Debug 编译 87512 退出 0，
执行 32864 已启动，共 535 项；256 MiB PE 栈及产物摘要见
`05-history-linear-debug-artifact.json`。完整 ReleaseSafe 编译 96375 尚未结束。
局部算法复杂度改善不代表已测得整体提速，Owner 全矩阵及第05项仍未验收。

完整 ReleaseSafe 80050 通过前 408/532 后在 OMS 四分片容量用例继续运行。对 PID 12364 的 500 个 native leaf 样本显示 `memcpyFast` 97.2%、栈探测 2.2%，见 `05-native-cpu-12364.json`；这是当前用例的指令样本比例，不是吞吐提升测量。Root 已停止该测试，80050 退出 -1，千单矩阵未完成。此前“仍在运行”是当时记录，不能沿用为当前状态。

只读清点发现五类 OMS 自有事务仍完整复制 15,488,768 字节状态。Root 在 `oms.zig` 使用仅含活动计数器、身份高水位、安全标志和最多 40 个受影响既有订单行的私有回滚记录；新订单与历史只追加，失败恢复原计数，未使用尾部仍不进入摘要或快照。数值 group identity 可能跨策略触及更多行，group/dispatch 在任何业务修改前检测该范围，并通过 never_inline 进入原完整候选事务；没有新增业务容量或错误。report/reconciliation 各捕获一个订单，replacement 捕获前驱，保留每类包装器原有错误安全标志行为。OMS 布局、公共 API、格式、校验及归档协议未改变。

新增公共回归覆盖第二成员失败、report 插入后拒绝、replacement 发出新命令时 overflow，以及 3/41 个跨策略同数值 group 的 dispatch 部分失败和再次成功。OMS 模块 Debug/ReleaseSafe 各 37/37 退出 0，见 `05-oms-undo-debug.log` / `05-oms-undo-releasesafe.log`。

当前 89 文件身份 `3b5802307eb4e41230d344364567de2d8b20477b7eef143d08d6095094639d75`，见 `05-oms-undo-source-manifest.json`（明确记录聚合算法）。纯 OMS 容量会话 76990 正在编译/执行；当前完整 ReleaseSafe/Debug 编译分别为 65544/70371。旧完整程序及应用构建身份不证明这份源码，后续仍需当前完整结果、应用构建及双轴复查。审查代理碰到额度限制未开始修改，第三轮实现由 Root 完成。

第三轮验证更新：纯 OMS 容量 76990 退出 0，42/42，通过四分片同时保留各 1,024 live + 3,600 terminal 及十轮至累计 4,240 terminal，编译加运行 113.48 秒（不是单独运行时间或同负载前后比值）。完整 Debug/ReleaseSafe 编译分别 70371/65544 均退出 0；完整 Debug 测试 12056、日志 `05-oms-undo-full-debug-test.log` 仍在运行，ReleaseSafe 尚未执行。

应用构建 45540 退出 0，66,644,480 字节，SHA-256 `17835aaeab06fbef5ea272c2e0e01564fad92591a67a631d5a1eba04b30f2e8e`，见 `05-oms-undo-build-artifact.json`。功能栈 256 MiB 的 CLI 构建 97760 退出 0；五 golden fixture 57351 和纯离线五角色链 49810 均退出 0，见 `05-oms-undo-cli-artifact.json` 及对应日志。末尾资格状态仍 blocked/production_qualification=false，不能将功能断言成功改称平台资格。

第三轮 Spec/Standards 两轴已在额度恢复后重新只读审查最新 OMS undo，均未确认剩余具体 P1/P2；旧两轮结论不替代这一复查。89 文件逐个重新校验与当前 manifest 一致。完整 Owner/Gateway 四分片容量、完整两模式退出结果及资源/平台资格仍待证据，第05项保持 in-progress。
