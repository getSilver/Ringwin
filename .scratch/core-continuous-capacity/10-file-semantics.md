# 10 Windows 文件语义与最小故障矩阵

2026-10-16，源码基线 `4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`；Zig `0.17.0-dev.315+5b647b792`。已读AGENTS、CONTEXT、ADR0004/0010/0011/0013、issue10及capacity-contract最新执行口径。本次仅源码/标准库追踪、官方资料核对和三字节native probe；未运行完整套件，未交易、访问凭证、修改ACL/系统配置或删除文件。

执行上限为每个夹具全分片live≤100、terminal≤100；原千单、压力、资源预算、索引成本及目标平台性能未测。本文不能将Windows普通文件重开或进程中断恢复升级为断电、Windows生产或Linux等价资格。

## 结论与确认缺口

`WindowsFileAdapter`目前是`LinuxFileAdapter`的类型别名（`src/durable_store.zig:1831`），`openWindowsVerification`只检查运行平台、建目录并使用`Dir.openDirAbsolute(...,.{})`。这复用存储协议，不提供相同OS耐久性。普通文件同步、同目录替换、发布根选择及内容校验可分别取得Windows功能证据。

**确认缺口：目录flush返回值被忽略。** `syncDirectory`（1814）在Windows调用`FlushFileBuffers(dir.handle)`，丢弃BOOL与错误码。实际Zig目录handle只申请READ_EA/TRAVERSE/READ_ATTRIBUTES、READ_CONTROL/SYNCHRONIZE，没有GENERIC_WRITE；官方FlushFileBuffers合同要求写权限并要求失败时读取GetLastError。[Microsoft FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)

已在本任务新建`.scratch/core-continuous-capacity/10-file-semantics-nativeprobe/data/`，用相同Zig目录打开方式运行两代三字节文件：

| 实际动作 | 两代结果 |
| --- | --- |
| `file.writeStreamingAll`及`file.sync` | 成功 |
| 原生`FlushFileBuffers(file.handle)` | BOOL=1、error=0 |
| `dir.rename(temp,dir,published)`，第二代替换既有目标 | 成功 |
| 原生`FlushFileBuffers(dir.handle)` | BOOL=0、GetLastError=5（ACCESS_DENIED） |
| 关闭写handle后重新打开目标读取 | 读到第二代`new` |

源码为[native probe](10-file-semantics-nativeprobe/probe.zig)，SHA256 `61f15cdcaf2dc3842fb4eaf89dc7d520e9e4e4b044ffa81e2f6ddb607b1be7f6`；原始输出为[output.log](10-file-semantics-nativeprobe/output.log)。命令：`zig run .scratch/core-continuous-capacity/10-file-semantics-nativeprobe/probe.zig -O ReleaseSafe`。目录已保留；probe故意拒绝复用已存在data目录，重跑应选新任务子目录。它没有测试掉电、驱动缓存、并发读者原子可见性或新进程恢复。

建议10报告增加明确字段`directory_flush_result=0`、`directory_flush_error=5`、`directory_durability_qualified=false`。若需代码修复，最窄是**不改变验证模式准入的可观测性**：保存最近BOOL/error和累计失败次数、公开只读观察，不改持久schema、不打印路径/身份、不把失败当成功。Windows生产准入仍关闭；未来生产专项另选并验证正确的目录/卷持久化方案。不能未经测试直接要求当前只读目录handle的flush必成功，也不应申请管理员权限或flush整个卷来让本票通过。

## 从Store到实际Windows syscall

以下标准库位置均为本机固定Zig安装的`lib/std/Io/Threaded.zig`，属于本轮实读源码，不是对新版本的推测。

| Store路径 | 实际Windows操作 | 可证明及限制 |
| --- | --- | --- |
| `writeFile`/`writeSnapshotFile`（1789/1796） | `Io.File.sync`→vtable.fileSync→`fileSyncWindows`（8629）→`NtFlushBuffersFile`；ACCESS_DENIED等返回错误 | 真正文件flush错误会向上传递，外围errdefer关闭Store gate；不代表目录名提交或设备掉电保证。官方说明flush请求下达文件系统；设备后续行为另有责任。[ZwFlushBuffersFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-zwflushbuffersfile) |
| `writeAtomicFile`（1806）、snapshot发布（1276）、manifest发布（1697）、业务根发布（1619） | `Dir.rename`→`dirRenameWindowsInner`（7516）；打开源文件申请GENERIC_WRITE+DELETE；`NtSetInformationFile(.RenameEx)`带REPLACE_IF_EXISTS/POSIX_SEMANTICS/IGNORE_READONLY，特定不支持状态回退`.Rename` | 实际不是MoveFileEx、ReplaceFile或所谓`renameAtomic`函数。所有Store临时/目标均在同一目录，避免跨卷移动。名字替换的功能语义与新打开者行为有官方说明；不据此推断断电持久性。[FILE_RENAME_INFORMATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information) |
| snapshot回收（1306–1319） | `Dir.deleteFile`→`dirDeleteFileWindows`（7110）→`dirDeleteWindows`（7246），`NtCreateFile`申请DELETE，`NtSetInformationFile(.DispositionEx)`；特定不支持状态回退`.Disposition` | 并非直接调用DeleteFileW；Ex优先使用POSIX删除语义。root/manifest先发布，再删除不再引用的旧snapshot。删除错误除FileNotFound外关闭gate；随后目录flush仍存在上述缺口。[FILE_DISPOSITION_INFORMATION_EX](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-_file_disposition_information_ex) |
| `openPath`（1007） | `Dir.openDirAbsolute(.{})`→`dirOpenDirWindows`（5378）→`NtCreateFile`，DIRECTORY_FILE/SYNCHRONOUS_NONALERT/OPEN_FOR_BACKUP_INTENT | backup intent打开标记不是启用权限；源代码没有GENERIC_WRITE，因此目录flush观察必须独立记录。 |

普通`append`（1123）重写segment经临时文件+真实file sync+rename，但manifest可非同步发布；`commit`和`seal`再次持久化segment及同步manifest。`persistSegment`（1658）始终对新segment inode做file sync，避免仅同步manifest就替换旧已提交文件。所有可见操作失败由Store外围关闭gate，唯一例外是目前被丢弃的Windows目录flush结果。

业务历史先向`order-history.objects`追加完整对象并`file.sync`，再重新读取验证批次，随后同步`order-history.roots.tmp`并替换根；`.commit`注入发生在根已发布之后。旧objects孤尾可以保留，但不因物理存在变成权威事实。

## 完整性、fallback与格式身份

- `loadManifest`（1061）验证magic、manifest schema3、头长、entry数量/编码长度和覆盖entries的CRC；entry绑定stream/domain、segment、序号、barrier、byte length、SHA256及两代snapshot引用。manifest坏、缺segment、内容摘要不匹配、archive root/sequence不连续均由`recoverImpl`（1323）失败关闭或返回RecoveryOnly；不会扫描目录猜选最新文件。
- snapshot对象外层格式schema1，验证domain/stream/barrier、长度、CRC和内容SHA256，并要求与manifest摘要一致（1707）。当前snapshot坏或缺失时可选manifest明确列出的previous；须加载连续tail并核对archive链，最多两个旧archive缓存，超预算拒绝。不等于任意旧snapshot都可回退。
- `recoverImpl`每次丢弃resident选择并重读磁盘manifest，避免用半变更内存root；fallback不修改磁盘。后续发布先验证当前或前代有效对象，保留两代可恢复根后才删除obsolete snapshot。
- `requireCurrentJournalSchema`拒绝未知journal schema，即使frame CRC和manifest摘要均有效。`snapshot_codec.readInto`（96）校验Core state schema、registry、release_artifact、encoding version、header CRC、payload CRC/SHA；`TradingShard.restoreSnapshotInto`固定传入预期身份，`Owner.recoverInto`（352）将失败转换为DecisionLogUnavailable并ready=false/closed=true。Store不理解Core release身份，不能只跑Store.recover就声称artifact不匹配已被拒绝。
- Core `release_artifact_identity`当前是源码常量1；该字段校验不是EXE SHA256证明。验收必须另存实际EXE hash、完整commit/diff及编译配置；用合法CRC的错误artifact header测试语义拒绝，不能仅破坏任意字节后将CRC失败称为artifact验证。
- Store可恢复旧或新完整字节根后，Owner还须验证全部派生事实组、经济状态/账本/累计量、control与history证明及dispatch命名空间。Store的`ready`不授予发送或新增风险权限；Unknown/accepted恢复必须在公共链核对零重发。

## 现有注入究竟证明什么

`Fault`和`FaultPoint`位于`durable_store.zig:89–90`；`injectFaultAt/injectFaultAfter`→`failAt`（1052）→`faultError`只在命中位置**直接返回命名错误**。`.short_write`不执行半段物理写入，`.corruption`不自动改坏文件，`.enospc/.read_only/.eio/.sync_timeout`不是OS真的返回相应错误。注入后成功执行的其他文件操作仍是真实Windows syscall。此类结果标为`deterministic_hook`。

同名点依操作语义不同：

| 点 | journal/snapshot路径 | business-history路径 |
| --- | --- | --- |
| append/commit/seal/rotate/publish | 该操作入口，尚未执行本操作实际I/O | append在HistoryObjects对象写入之前；commit在新roots替换及目录flush尝试之后 |
| snapshot_sync | snapshot临时文件已写完并真实file sync，尚未rename | roots临时文件尚未写入 |
| archive_sync | archive page已实际写入/同步/rename，forward ref尚未写入 | objects已追加、尚未file.sync |
| root_publish | manifest.tmp已写入（是否sync由调用决定），尚未rename | roots.tmp已同步、尚未rename |
| reclaim | 新snapshot/manifest引用已发布，尚未删obsolete对象；rotate也有尾部点 | 业务历史发布无此点 |

既有`checkpoint store file fault boundaries select complete old or new roots`为5种错误×9点，文件是真文件但错误为hook；`order history file publication fault boundaries reopen a complete old or new root`覆盖5点及业务根旧/新选择。另有物理破坏测试实际截短、改字节或删除本测试文件，类型应标`physical_file_mutation`。这些fixture同进程重建adapter不是独立新进程，也不是断电。

`runWindowsAcceptance`（2284）是Windows真实小文件重开，但打印`faults=memory`，不能复用其成功输出声称文件fault matrix或新进程恢复完成；固定`C:\Windows\Temp\ringwin-durable-store-PID`开头有cleanup，10新runner宜使用任务新建唯一目录并保留原始结果，不复用预先清理目录路径。

## 最小可复用矩阵建议

所有case新建独立子目录、≤数个真实订单；可复用09小链中的同一业务状态，不运行500观察/千单三遍。每个case保存before/after根与barrier、完整经济/账本摘要、占用及Unknown/accepted计数、恢复耗时、gate、send计数、退出码和失败理由。

| 组 | 最小case | 要求 |
| --- | --- | --- |
| A 普通持久重开 | 10轮小生命周期，每轮归档/checkpoint，关闭所有handle；父进程启动全新recover子进程 | 读取磁盘、不传内存snapshot；Owner/Gateway/RawIngress一致；accepted与Unknown零重发 |
| B 命名hook | journal/snapshot的9个FaultPoint各一次`.eio`；business-history额外5个点各一次`.sync_timeout` | Store即时关闭；新进程只恢复预期旧/新完整根；标deterministic_hook，不能称真实EIO/timeout |
| C 错误分类 | 选入口append或commit分别注入short_write/enospc/read_only/sync_timeout | 验证错误分类和上层撤权；不填满真实卷、不改ACL，不将命名错误当真实磁盘状态 |
| D 真实字节损坏 | missing segment、坏manifest CRC、truncated active tail、bad snapshot当前/两代均坏、history roots缺失/objects截短，各独立副本 | 当前snapshot单坏仅允许合法前代+连续tail；其他应关闭。修改/删除只限本任务新建case目录；不自动修复原目录 |
| E 语义身份 | journal未知schema且checksum合法；Core state/registry/release artifact不匹配且外层hash/CRC合法 | 必须到公共Owner恢复拒绝，而非只靠文件CRC失败 |
| F 进程中断 | writer在snapshot临时文件flush后/roots rename前/manifest已发布后/reclaim前通知父进程并停止，再由父进程终止**该任务子进程** | 真正进程结束后全新reader恢复；标process_termination；这仍不模拟掉电或缓存丢失。现有错误hook不足以精确停止在所有syscall边界，可增加fixture观察callback/子进程阶段协议，勿改业务权威布局 |
| G 平台语义观察 | 本文nativeprobe；可再在同目录先持有旧目标读handle，再replace观察新打开读者与旧handle | 记录实际成功/失败与errorcode；RenameEx是否走fallback需额外观察，未采集则not_measured；directory flush失败单列，不伪造成功 |

如果时间受限，A、B的每个语义阶段、D/E和至少两个F（发布前、发布后）是功能证据最小主干；C与G不能由Linux结果代替。所有未执行case写not_run，不用“预期”填pass。业务根与manifest是两个不同提交点，必须各有一个发布前/后case。

## 无敏感字段的本机metadata命令建议

根代理负责实际采集；这里仅列只读命令，不输出hostname、用户名/SID、卷GUID/标签、设备序列号、PnP DeviceID或ACL IdentityReference：

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
Get-Volume -DriveLetter D | Select-Object FileSystemType,AllocationUnitSize,Size,SizeRemaining,HealthStatus
Get-Partition -DriveLetter D | Get-Disk | Select-Object Number,FriendlyName,BusType,PartitionStyle,LogicalSectorSize,PhysicalSectorSize,IsReadOnly,IsOffline
Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in @('SCSIADAPTER','DISKDRIVE') } | Select-Object DeviceClass,Manufacturer,DriverVersion,DriverDate,IsSigned
$taskAcl = Get-Acl -LiteralPath 'D:\github\Ringwin-core-continuous-capacity\.scratch\core-continuous-capacity'
[pscustomobject]@{ Rules=$taskAcl.Access.Count; Protected=$taskAcl.AreAccessRulesProtected; Explicit=($taskAcl.Access | Where-Object { -not $_.IsInherited }).Count; Deny=($taskAcl.Access | Where-Object AccessControlType -eq Deny).Count }
$taskIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskPrincipal = [Security.Principal.WindowsPrincipal]::new($taskIdentity)
[pscustomobject]@{ IsSystem=$taskIdentity.IsSystem; Administrator=$taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
```

ACL聚合不是有效权限证明；本任务小目录的create/write/sync/rename/reopen/delete各操作返回值才是对应功能观察。不得为采集metadata提升权限或更改ACL。Get-Volume/存储cmdlet不可用或被拒绝时保留错误为not_collected，不能猜测FS/driver。
