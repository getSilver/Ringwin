# 06 核实并封闭 manifest 发布耐久性窗口

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: resolved
Evidence level: 静态风险 R1；未复现目标文件系统断电损失

## Question

advisory manifest 更新替换恢复索引时，是否保护全部先前提交的 barrier、snapshot 和 archive 根？

## Problem Statement

普通 append 使用 sync=false 发布 manifest，其临时文件和目录不走同步分支。
manifest 同时包含先前 commit 的恢复引用，不能因为新 append 未提交就把整个索引视为可丢。

## Solution

先按当前调用链和平台合同证实或排除风险；若缺陷成立，在现有 Store 中以最小改动保护已提交恢复索引。

## User Stories

1. 作为账户所有者，我希望后续 append 不破坏先前提交索引，以保持确认状态可恢复。
2. 作为恢复执行者，我希望发布各阶段可判定，以免不完整发布被当成成功。
3. 作为审计者，我希望区分 ReplayRPO 与 EconomicRPO，以免误报资金损失。
4. 作为运维人员，我希望平台分别验证，以免一个系统的结果代替另一个。
5. 作为维护者，我希望先复现或反证，以免凭推测重写存储。
6. 作为恢复执行者，我希望其他 stream 的根也受保护，以免单流更新伤及全局索引。
7. 作为审计者，我希望缺少目标证据明确未测，以免单测升级生产资格。
8. 作为维护者，我希望复用 Store seam，以免出现第二套持久化系统。

## Implementation Decisions

- 列清 append、commit、seal、snapshot、rotate 的 manifest 写入/同步顺序及旧提交依赖。
- 分别核对内存、Windows 与 Linux 文件 adapter，不因共享代码或别名推断 OS 等价。
- 确认缺陷后在现有 implementation 修复；只同步 segment 或保留内存 manifest 不能替代恢复索引保证。
- ReplayRPO 允许的未提交尾损失不能破坏先前提交索引，也不能隐藏真实物理证据。
- 不预选双 manifest、数据库或专用线程；优先证明最小发布顺序和错误传播满足合同。

## Testing Decisions

- 公共 Store 操作与重开为测试面，注入 write/sync/rename/目录同步各阶段故障。
- 先建立已提交状态、snapshot/archive 根，再执行普通 append，检查旧引用。
- 至少覆盖两个 stream，避免只检查当前追加对象。
- 故障注入、进程退出与真实断电分别记录；目标平台实验未执行时标 not_run。
- 排除风险需要当前实现、平台保证及可执行反证，不能仅引用通过计数。

## Acceptance Criteria

- [x] 完成持久化顺序及平台保证矩阵，区分已证实、已排除和未测条件。
- [x] 若缺陷成立，先有失败回归，再修复后续 append 对旧提交索引的影响。
- [x] 同步/发布错误传播并关闭既有安全入口，不隐藏错误。
- [x] 多 stream、snapshot/archive 旧引用保持可验证；有歧义状态明确拒绝而不猜测。
- [x] 本票最小定向可控故障验证有记录；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行；未做真实断电则保留目标资格缺口。
- [x] Answer 写明修复或有充分证据的排除；未测不能充当排除。

## Out of Scope

自动执行目标机断电、取得生产资格、引入新存储框架、重复 05 的尾部可见性修复。

## Further Notes

ready-for-agent 表示可以开始核实，不表示损失已证实。可复用 05 的恢复回归，但无硬依赖。
来源见[审阅证据](../evidence.md)。规格发布阶段未实施；2026-11-04 的实施与验证证据见 Answer。

## Answer

2026-11-04：本票实现、Debug 定向验证与两轴复审已完成，resolved。确认普通 append 跳过全局 manifest 同步的静态风险；已修复该发布顺序并通过最小 Debug 定向验证。没有复现或声称目标文件系统断电丢失。模块最终 ReleaseSafe 待验。

### 源码身份与影响范围

- 基线：`1d533b5ba7c8ca3a5cff3f78993def5a71e57f7b`；实现提交：`a9c9a77fe680c2be0c9b96d0204ce0b7fe01ff49`；Windows 错误传播补修及最终源码：`3781870cd08153fb0c7b50a2347133d26ce158ec`。
- 仅修改 `src/persistence/durable_store.zig`，SHA256：`D43F634DEC5A1DD9BBC3CD2F0AA10424EF7DEC4336B38D3175E775A1BCAEEB93`。
- `appendImpl → persistSegment(false) → writeManifest(false)` 原来将没有 file sync 的临时文件 rename 成唯一全局 manifest，且没有目录同步。它包含所有 stream 的已提交屏障、snapshot 和 archive 引用，因此新 append 的 ReplayRPO 不能成为整个索引可丢失的理由。这是源码确认的缺失同步风险，不是已观察到的 EconomicRPO 违反或资金损失。
- 移除 `persistSegment`、`writeManifest` 的 sync 参数，统一同步发布 manifest；其调用者 append/commit/seal/rotate/publishSnapshot 及两个内部故障 fixture 已同步更新。Store interface、manifest schema 3、journal/snapshot codec、CanonicalStateDigest 均不变，无迁移或旧状态改写。
- 新增四个精确 FaultPoint，复用已有注入机制；保留 root_publish 的既有位置和语义。错误向公共 Store 调用者传播并锁存 gate，后续 append/commit/seal/snapshot/rotate 拒绝。未新增持久化系统、线程、配置或依赖。
- Windows 既有目录 flush 忽略错误，且原目录句柄没有 GENERIC_WRITE。现以原句柄为 RootDirectory、空相对名称，用 NtCreateFile 打开同一目录的独立有写权限句柄；不通过路径重新定位目录，检查打开与 FlushFileBuffers 返回值并关闭句柄。打开或同步失败返回 DirectorySyncFailed，由既有 Store 写入口锁存 gate。修复覆盖所有既有 syncDirectory 调用者，含 segment、manifest、snapshot、archive 和 order-history 根。
- MemoryAdapter 不涉及真实文件发布；保持其确定性内存状态与故障合同，不将它作为耐久性证据。

### 当前发布顺序与旧根依赖

以下“同步”表示实际调用该平台的既有 file sync / syncDirectory，平台限制见下一表。全部路径由同一个 Store implementation 拥有。

| 公共操作 | 最终顺序 | 对旧提交的影响 |
|---|---|---|
| append | segment.tmp 写入 → file sync → rename segment → directory sync → 更新内存 entry → manifest.tmp 写入 → file sync → close → root_publish/rename → directory sync | 新物理尾不提升 committed_barrier；始终同步全局恢复索引，包括其他 stream 的旧根 |
| commit | 校验 barrier → 更新内存 barrier → 同步 segment → 同步 manifest | 只有全部成功才能返回提交成功；失败关闭，不用内存候选替代磁盘根 |
| seal | seal journal/footer → 同步 segment → 同步 manifest | 保留既有提交屏障，不借 seal 提升未提交尾 |
| publishSnapshot | 校验 sealed/committed → 写 header/payload 临时对象 → file sync → snapshot_sync 故障点 → rename 对象 → directory sync → 更新当前/前一 snapshot 引用 → 同步 manifest → 更新缓存 → reclaim | manifest 成功前不回收旧快照；失败保留旧对象或完整新对象，恢复按磁盘索引校验 |
| rotate | 校验 seal/snapshot → 同步 archive page → archive_sync 故障点 → 同步 forward index → 更新 archive root/active index → 同步新 segment → 同步 manifest → reclaim | archive/快照对象先于发布引用；失败不猜测升级 barrier，05 仍保留物理证据 |

### 平台保证与证据矩阵

| 实现/条件 | 当前源码与系统合同 | 本轮结论 |
|---|---|---|
| MemoryAdapter | 无文件系统；commit/恢复由内存模型提供 | 不涉及 OS 发布风险；不能证明掉电安全 |
| 原生 Linux，目录 fsync 受支持 | file.sync 走 Zig fileSyncPosix；rename 后显式 fsync(dir)。Linux 文档指出 file fsync 不自动保证目录 entry，需另同步目录 | 修复补齐缺失的 manifest file/directory sync；源码核对完成。原生 Linux 文件系统、进程退出、真实断电均 **not_run**，未排除硬件/文件系统故障 |
| Linux EINVAL/OPNOTSUPP，含 legacy WSL1 | 既有 syncDirectory 回退 std.posix.sync，无逐目录可返回的错误证据 | 源码已核对；本轮不扩大为受支持的生产耐久性保证，未测 |
| WindowsFileAdapter / WindowsVerification | 别名不证明等价；file.sync 走 Zig NtFlushBuffersFile 并传播错误，rename 走 NtSetInformationFile。旧 syncDirectory 忽略 FlushFileBuffers(dir.handle) 结果，且目录 open 没有 GENERIC_WRITE；已改用同目录独立写句柄，打开与 flush 均检查结果 | 本轮 Windows 原生目录写句柄打开/flush 成功、实际文件重开、真实共享冲突错误传播和确定性阶段故障均通过。API 成功与错误路径已有证据；随机退出/真实断电及目标文件系统资格仍 **not_run**，不授予 Windows 生产资格 |

系统合同来源：[Linux fsync(2)](https://www.man7.org/linux/man-pages/man2/fsync.2.html)、[Windows FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)。本机 Zig `0.17.0-dev.315+5b647b792` 的 `lib/std/Io/Threaded.zig` 中 dirOpenDirWindows、fileSyncWindows、dirRenameWindowsInner 已按当前源码核对。Windows 原生成功返回只证明同步调用可执行，不能代替断电后命名与内容耐久性资格。

### 反例、故障矩阵与实际验证

- 在旧 sync 条件分支内加入同步阶段故障点，并通过公共 Store append 执行原路径；先失败：`expected error.SyncTimeout, found void`。红灯证明原 append 根本不经过同步分支；它不是模拟断电后已提交事实丢失的证明。日志 `.scratch/build/source-audit-06-red.log`，退出码 1。
- 正式回归 `advisory append preserves committed multi stream manifest roots at publication faults`：decision_log 与 raw_ingress 两个 stream 各自 append/commit(1)、seal、publishSnapshot(1)、rotate、append/commit(2)，再只对第一个 stream 普通 append(3)。两个旧 snapshot 字节分别为 71/72，独立保存各自 archive root。
- 在 manifest write、file sync、rename、directory sync 及原 root_publish 五个发布边界，分别注入 short_write、sync_timeout、EIO，共 **15** 个故障组合；另有 **1** 个无故障成功场景。注入发生在边界前，不声称模拟了部分磁盘写入、OS flush 失败或真实掉电。每个故障均返回对应错误，gate=closed，随后五个写入口拒绝。
- 每次新建 adapter 从同一目录重开两个 stream：snapshot_barrier=1，快照字节相同，committed_barrier=2，归档根仍能通过公开 verifyArchiveReceipt 验证；当前 stream 保留物理 last=3，另一 stream last=2，两个已提交 tail 都只重放 sequence=2。目录同步故障位于 rename 后，验证完整新索引；其他点保留旧索引。全部不将 sequence=3 提升为已提交。
- 新增 Windows 专项公共 Store 回归：完成已提交 snapshot/archive/sequence=2 后，在 manifest rename 成功和目录同步之间，通过 I/O 边界获得一个不共享写权限的真实目录句柄，制造 OS 级 sharing conflict；没有直接注入 DirectorySyncFailed。旧实现先失败：`expected error.DirectorySyncFailed, found void`；修复后打开同步句柄失败被传播、gate=closed、commit 拒绝；重开 committed=2、physical last=3、snapshot=1/73 和旧 archive root 可验证。日志 `.scratch/build/source-audit-06-windows-red.log`，红灯退出码 1。Windows 以外跳过此专项回归，不将其算作 Linux 验证。初版 fixture 在 rename 前取得锁导致 rename 自身失败，已移到成功 rename 后；该 fixture 失败不计业务红灯证据。
- 既有 5×9 文件发布故障矩阵、committed recovery prefix 回归和实际 Owner 物理 suffix 回归继续通过。Owner 只恢复已提交经济状态、保持隔离并拒绝后续副作用；无尾正例仍满足现有恢复准入。
- 新测试与实现共置；`src/main.zig` 已导入 durable_store，新增回归进入最终全量入口，不需单独构建程序。

平台：Windows 原生 PowerShell；Zig `0.17.0-dev.315+5b647b792`；Debug；沿用仓库 512 MiB 测试栈。

```powershell
python tools/zig-entry.py test src/persistence/durable_store.zig -ODebug --stack 536870912 --test-filter 'Windows store directory sync access failure' --test-filter 'advisory append preserves' --test-filter 'checkpoint store file fault boundaries' --test-filter 'committed recovery prefix'
python tools/zig-entry.py test src/runtime/demo/demo_authority.zig -ODebug --stack 536870912 --test-filter 'physical crash suffix'
zig fmt src/persistence/durable_store.zig
git diff --check
```

- Store **6/6**，退出码 0；包含共享入口、新 Windows 真实共享冲突回归、新多 stream 发布回归、既有发布矩阵及两个 committed-prefix 回归。
- Owner **3/3**，退出码 0；包含共享入口、实际 Owner 重开及导入的 Store physical suffix 边界回归，不重复计算独立覆盖。
- 日志：`.scratch/build/source-audit-06-store-debug.log`、`.scratch/build/source-audit-06-owner-debug.log`。fmt/diff check 通过。
- 初审规范 0 项；规格发现 1 项 Windows 同步错误隐藏，已补修并增加上述原生错误回归。规格复审 0 项剩余发现；规范复审 0 项违规/异味。本票不运行全量。07 尚未实施，最终 ReleaseSafe 仍 pending；所有修复和审查完成后在最终源码统一执行。
- 未读真实凭证，未访问 Demo/Testnet，未下订单；Linux 原生、随机 kill、真实断电、Windows 断电目录耐久性、容量/延迟和生产资格均未验。本次增加每次 append 的 manifest file sync 与目录同步调用，未量化额外延迟，不宣称吞吐收益。
