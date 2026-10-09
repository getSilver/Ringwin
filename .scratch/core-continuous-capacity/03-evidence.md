# 03 检查点与日志轮转证据

Status: resolved

本票在独立工作树 `D:\github\Ringwin-core-continuous-capacity`、分支
`codex/core-continuous-capacity` 实施。审查基线为 `fab0732b`，当前业务源码为
`b5bb660752648012ffde5c9caf4157fa3f8c655c`，Git tree 为
`dbb8bce2d7a4147c45c011e529aaf0f178548384`。最终 Debug/ReleaseSafe 全量验证已完成。
本票结果不授予千单、平台或 Venue 资格。

## 提交与恢复合同

Owner 在权威屏障 B 封存已提交 journal，发布与 B 绑定的快照，再轮转 Store。
Store 的不可变归档描述符绑定 stream、连续区间、段载荷摘要及前一根；活动
manifest 仅保留每条 stream 的当前入口。Owner 核对实际封存载荷与归档回执后，
将检查点确认作为 B+1 的权威事实提交，核心才迁出旧 Trace 窗口。

检查点根同时绑定旧检查点根、有序事实链、完整规范输入内容链、当前权威
状态与被引用事实。核心不执行磁盘 I/O。格式身份演进为 journal 32、state 36、
registry 30 和 StateDigestV7；旧格式失败关闭。

恢复本身不写入或发送。若中断发生于 seal、snapshot 发布或 rotate 之后，
Owner 保留待完成状态并拒绝其他输入；调用显式 checkpoint 才提交确认。
已发布的同屏障快照复用原字节；同屏障不同载荷失败关闭。

Raw DurableSink 也保留已恢复的 sealed 状态；显式 checkpoint 完成或确认既有
轮转后才允许下一帧。恢复保持原提交水位与段摘要，pending 期间拒绝 append
不触碰 Store；重复完成不会再归档同一段。

Store 保留最近两代有效完整快照；发布并同步新根后才删除已无引用的旧快照。
归档段载荷仍保留，本票没有实现保留到期删除。最近快照损坏时仅允许已验证
的上一代与连续尾部；一次坏最新快照之后的再次发布保留上一份有效备份。
回退最多承接两条归档段与活动段，共三条有界尾部；超出、缺段或混合根失败关闭。

私有输入采用完整帧边界，而不是推测 canonical cursor。适配器仅在 ready、
完全 drain、全部 Owner 提交后导出有界纯数据 seed；原始输入段先封存与发布，
decision 快照绑定 raw stream、水位、归档根、seed 摘要和 canonical 身份。
恢复先还原适配器 seed，再验证及重放边界后的有界 decision/raw 尾部。
seed 不含 transport、凭证、执行权限或指针。

现有 Windows 多进程 IPC 只传 core snapshot，尚不能传递私有 seed；该路径对
seeded 边界显式拒绝，不将空尾部解释为恢复完整。票 10 必须贯通跨进程 seed
传递并验证实际重启；本票的私有 seed 结果只覆盖同进程公共 Owner/Adapter seam。

## 已取得的局部结果

- Core 100 轮公共检查点测试通过，屏障到达 929；见
  [原始日志](03-core-checkpoint-final-debug.log)。当次 core snapshot 为 89,683 字节，
  TradingShard 布局为 122,352 字节；这不是票 09 的运行时内存或栈资格。
- Store 十二项检查在最终 Debug/ReleaseSafe 全套中通过，包含 100 轮内存/Windows
  文件轮转、七 stream、45 个文件故障组合、两代快照与有界尾部读取。
  最新局部 Debug 为 [12/12](03-store-debug.log)；旧局部 ReleaseSafe 日志在新回退
  fixture 前为 11/11，不代替最终源码全套证据。首轮无快照日志、回调写入、
  根承接、未知 record schema 和回退后再次发布均已覆盖。
- Owner 100 轮内存及实际 Windows 文件重开、私有 seed 自持有和混合元数据拒绝、
  外来 decision namespace 拒绝、seal/publish/rotate 显式承接恢复均通过最终 Debug。
- 新公共 Owner → FileStore 检查覆盖 18 个边界 × 5 种确定性注入错误，共 90 例。
  Debug/ReleaseSafe 各 2/2，见 [Debug](03-owner-file-fault-debug-final.log) 与
  [ReleaseSafe](03-owner-file-fault-releasesafe.log)。逐例比较一个完整旧、确认前或新
  状态的 canonical 摘要、有序链、pin/检查点根、OMS、经济、占用和权限，并再次
  重开；未提交尾部失败关闭，Gateway 发送次数保持零。所有 root 发布及两处
  reclaim 均实际命中，不能独立挑选旧/新屏障、快照及归档根来凑成功。
- 上述错误码注入不是实际短写、物理磁盘满或断电。每例还实际写入不完整
  `manifest.tmp` 验证其不能替代已发布根；真实快照截断、坏载荷和缺失归档段
  另有文件改动检查，见 [复用检查](03-owner-file-corruption-reuse-debug-large-stack.log)。
- 私有边界 Debug 3/3 通过，见 [日志](03-private-debug.log)：8 个合法新 session
  的 1,152 条实际 WS 更新产生 2,304 条 canonical account 输入；最新 seed 的
  空尾部恢复不扫描旧 epoch、不发送。另一实际初始 session 验证 seed 后新建单、
  同帧只提交 Report、恢复补回缺失 Fill 一次，重复不改变摘要和经济。
- Raw 的 seal/publish/rotate 三个中断位置经显式完成后均从 B+1 继续，回放
  精确两帧；Debug/ReleaseSafe 各 2/2。见
  [Debug](03-raw-resume-debug.log) 与 [ReleaseSafe](03-raw-resume-releasesafe.log)。

Store 每 stream 驻留缓存 196,672 字节，活动 manifest 编码上限 8,208 字节；
归档描述符与 forward reference 编码合计 192 字节。实际文件系统 allocated
bytes 尚未测量，不能将编码长度宣称为物理存储预算通过。适配器 seed 当次
测量 61,879 字节，组合快照 151,815 字节，因此 Store 单快照上限调整为 256 KiB。

归档回放回调可执行 Owner 提交；FileAdapter 使用独立的 192 KiB 回放缓冲，
避免其他 stream 的写入覆盖正在遍历的归档载荷。此后 FileAdapter 布局为
4,463,768 字节（另含两条有界回退归档缓冲及注入计数）；这些缓冲为 adapter
共享，未增加每 stream 缓存上限。

固定 V7 摘要迁移先保留失败，再运行既有五条轨迹的独立业务状态与重放断言；
见 [观测](03-trajectory-golden-observation.log)、[轨迹通过](03-trajectory-golden-green.log)
和 [四分片通过](03-shared-golden-green.log)。旧期望值导致的失败分别保存在
[轨迹 RED](03-trajectory-golden-red.log) 与 [共享摘要 RED](03-shared-golden-red.log)。
duplicate-report 的最终轨迹摘要现在与 happy-path 不同：其最后一个核心 mark
输入的时间不同，新版完整输入链将该差别纳入承诺。原有重复 Fill 无副作用及
独立业务、快照和重放比较均保留。

## 审查与最终验证

GPT 6.1 Sol、中等强度并行双轴审查，随后对修订源码复核。Standards 最终 0 项
硬性违规、0 项 actionable smell；原共享检查点提交状态转换的重复建议通过
`commitCheckpointReceipt` 解决。Spec 原 P2 为文件边界故障缺少完整业务状态证明，
已由 90 例公共 Owner/FileStore 回归及重复重开解决，无剩余代码发现。

当前源码最终 Debug/ReleaseSafe 全套各 450/450，见 [Debug](03-final-full-debug.log)
与 [ReleaseSafe](03-final-full-releasesafe.log)；前一源码
`b3e28f5e` 的 Debug/ReleaseSafe 各 449/449 另保留，不能替代修订后的全套。
ReleaseSafe 构建退出码 0、stdout/stderr 为空，见 [日志](03-final-build-releasesafe.log)
与 [构建身份](03-build-metadata.json)。测试显式使用 64 MiB 栈；不证明生产栈预算。

`zig fmt --check` 对所有修改 Zig 文件、`git diff --check` 通过。原始日志、长度
和 SHA256 见 [清单](03-log-hashes.json)。源码提交和该清单共同界定本票验证身份。

## 失败与剩余范围

全部 RED、整套中间失败和修订前成功结果保留。首次全套在 259/449 处因非法
IntentGroup 计数编码越界终止，另有旧 schema 错误类型、检查点后的屏障期望、
已锁存 Gate 的测试复用失败；共享编码入口及对应合同检查已修正。随后整套
446/449、448/449 的失败揭示待完成检查点与私有回放 fence 的承接问题，已由
真实文件回归修正：历史重放只临时绕过新输入 fence，结果仍保留 fence；私有
回放完成且检查点确认持久提交后才解除恢复准入。失败日志分别为
[首次](03-full-debug-initial-fail.log)、[第二次](03-full-debug-second-fail.log)、
[第三次](03-full-debug-third-fail.log)，不将后来通过覆盖为从未失败。

本票只关闭检查点、窗口承接及局部文件一致性。票 04–12、每分片 1,024 live、
订单/经济/控制历史查证与保留删除、整波资源预算及两平台文件容量均未完成。
Windows/Linux 实际进程终止、物理错误和平台资格仍由 10/11 及生产专项验证。
