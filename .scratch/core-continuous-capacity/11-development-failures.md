# 11 开发期失败及未执行候选

以下结果均保留，不计作最终冻结验收：

- 首次 PowerShell 的未加引号 `-femit-bin` 被拆为两个参数，编译器拒绝 `unrecognized file extension`；随后使用单个完整参数。
- `11-red.log`：扩展原公共文件回归到Linux，实际失败 WindowsRequired。`11-red-build.log`及原Linux binary保留本地。
- `11-green.log`：主线程8MiB导致SIGSEGV。诊断未自行退出时，仅终止本次owned PID 5。`ulimit -s 262144`实际返回Invalid argument，OS hard limit仍8MiB。`11-green-stack-build.log`的显式GNU_STACK候选只编译、未运行；不称其通过。
- `11-targeted-rs.log/result.json`：5 passed/3 failed（Unexpected、CoordinatorWriterClosed）。statx在旧WSL1不可用，分别暴露报告长度读取与Store无历史恢复。该开发运行期间源码曾推进，result保留source_mismatches_after；不能作为冻结源码证据。v2仅编译未运行。v3修复后真实8/8通过，source/producer drift为0。
- 初次应用smoke `11-preflight-v3`在启动业务子进程前，WSL Git不能解析Windows worktree `.git` 中的D:/路径；父工具原始错误为 `fatal: not a git repository: /mnt/d/github/Ringwin-core-continuous-capacity/D:/github/Ringwin/.git/worktrees/Ringwin-core-continuous-capacity`。该次没有持久文件业务命令结果；空证据/数据目录保留在lxfs。
- `11-preflight-v4`实际seed/recover均退出0，随后检测到producer漂移而停止。原因是代理在运行中编辑了worktree路径解析，属于采集器保护命中，不作为通过。两个原始process result和identity在lxfs保留，后续另以新prefix重跑。
- `11-preflight-v5-launch.*`：应用12个新进程smoke全部通过；包含一次归档、两次SIGKILL及500组合实际seed/recover。它是开发预检，不代替十轮与最终套件。
- `11-adapter-v3`旧strace：真实adapter目录fsync返回EBADF，随后走全局sync。根因是固定标准库对不迭代的目录打开使用O_PATH；普通Python目录探针成功不能证明此路径正确。后续修复Linux目录打开为iterate=true，BADF不再静默回退，并新增真实adapter syscall审计。
- 双轴初审Spec发现最终导出路径转换匹配了双反斜线，未正确转换Windows单反斜线路径。采用已明确的WSL_OUT拼接路径修复；在运行最终流水线之前完成。

最终v1（source2395154d）已构建应用/CLI并通过实际adapter同步探针。全量前补查旧Store测试发现其直接借用tmpDir(.{})的O_PATH句柄；公共Store指定回归实际red=DirectorySyncFailed，修复17个Store和2个Owner临时目录选项后green=1/1。v1在app第一轮恢复时因该源码变更命中漂移保护停止，原始run-state/result/log与冻结source.zip保留；ReleaseSafe/Debug完整套件均未启动。新候选source ad5437cd另以v2重新冻结，不能承接v1半程结果。

最终v2（核心source ad5437cd）应用30进程全部退出成功，十轮、两次SIGKILL及500组合均通过；随后物理审计错误地把allocation观测计入内容身份而报Retained physical dataset drift。五个数据集路径/长度/SHA均一致，选中的末记录也正确；主链order-history.objects长度205348且SHA不变，allocated bytes可由229376/262144收敛到208896。见11-final-v2-allocation-diagnosis.json及11-allocation-real-regression.json。修复只涉及采集/审计：内容身份比较路径/长度/SHA，继续完整保留raw allocation。3条独立回归实际red→green，真实五数据集回放通过且同长度内容损坏仍拒绝。v2的CLI链与完整ReleaseSafe/Debug均未执行；另以v3冻结新的producer，不回写v2身份或承接其半程资格。

本地旧binary、物理数据和原始日志不清理。目标断电、真实syscall内随机终止、真实磁盘ENOSPC/EIO、千单容量/压力、OS峰值RSS、完整allocated disk、实际线程栈峰值、索引成本、真实NodeFence、dump和Linux生产资格均未运行或未测。成功、失败和not_run不能合并成“全部通过”。

最终v3（source ad5437cd）两组应用/CLI各30进程、十轮、SIGKILL、500组合、两组物理数据审计及实际目录fsync均通过。完整ReleaseSafe随后在568号旧IPC测试失败Unexpected，在616号旧OKX内存Owner测试SIGSEGV，panic诊断受缺失statx影响未退出；外层10800秒timeout终止，Debug未启动。原始log及外层result保留，内层capture未完成而无result；不能称v3全量通过。

11-ipc-v2-red.trace.log以直接模块测试重现memfd_create ENOSYS。旧WSL1缺少该能力，不修补生产IPC或改成不安全映射；测试入口仅对原始memfd syscall ENOSYS返回SkipZigTest，其他错误失败且保留全部bridge断言。11-ipc-v3-capability-run明确0 passed/1 skipped/0 failed，该IPC能力仍未验证。

11-owner-stack-v2-red-run直接模块测试重现SIGSEGV；将Owner.bootstrap改成现有bootstrapInto的单变量试验v3仍SIGSEGV，故撤销。仅将两个旧测试自建worker栈从64MiB改成256MiB，11-owner-stack-v4-green-run实际1/1通过；业务函数、生产栈、断言和夹具输入不变。挂起诊断进程均检查/proc对应命令后只终止本次owned PID；v2/v3结果保留exit=-9，不称自然退出。名称含final-tail-red、ipc-red和owner-stack-red的首次main.zig过滤候选只运行根main.test_0，不能作为目标用例red/green证据；实际复现使用对应模块为root。

新source 6cd51582及新审计producer另以v4冻结。Linux完整套件允许且仅允许上述明确IPC skipped，该能力和目标平台资格仍未取得。用户已授权票11完成后继续12，尚未绕过11 blocker。

v4同源应用/CLI各30进程、十轮、物理审计及目录探针均通过，完整ReleaseSafe实际623 passed/1 skipped/0 failed（3191.629秒，源码/producer均无漂移）。完整Debug在84号recovery_cutover测试SIGSEGV后诊断挂起。用户要求终止后，核对/proc命令仅终止自有Debug PID5；内层capture保留exit=-9、elapsed10239.429秒，后者包含挂起而非正常测试耗时；外层exit247。未覆盖或修改失败结果。

直接模块Debug定向11-cutover-stack-red重现同一SIGSEGV；strace显示256MiB线程mmap基址0x7f6947210000、可写区从0x7f6947211000开始，故障地址0x7f6947210c30在guard页。只增加独立测试runner到512MiB，11-cutover-stack-green-run实际1/1通过；完整115份源码仍为6cd51582，生产逻辑和应用64MiB栈未改。原256MiB runner保留不改，新512MiB版本及来源分别记录，实际栈峰值仍未测。

按用户“继续跑剩下的”，v5明确为组合续验：复用同源v4 ReleaseSafe、60个业务子进程和三份ELF，所有别名保持原始bytes/命令/时间并逐项绑定来源SHA；重新审计实际五加五数据集，只新建完整Debug512MiB构建/执行。源码archive保留原producer并追加续验脚本/runner/audit身份；不把复用记录声称为v5新执行，也不删除v4失败。无新的Core业务源码变化，不重复已通过的ReleaseSafe或60进程业务链。

v5完整Debug越过原84项，在316项venue_fill_recovery_acceptance中panic: switch on corrupt value；原始日志及exit=-9/外层247均保留，未完成。14条NativeAssetCapacityExceeded是45-fill负向容量场景的预期输出，并非panic根因。直接模块11-private-fill-red重现同一panic，30秒超时保留；双轴审查共同定位旧测试433/439整对象std.meta.eql读取AccountProjection.seen有效计数之外的undefined tagged union。只改测试比较helper：核对所有元数据、四个计数与四数组有效前缀，原Owner/recovery/digest断言全部保留，不初始化生产闲置尾部掩盖读取错误。

新源码244f3ae7的公共用例Debug1/1、ReleaseSafe1/1通过，整个venue-fill模块及依赖Debug实际322 passed/1 skipped/0 failed（867.177秒），包含两个private checkpoint和相同IPC能力skip；源码和producer均无漂移。相关原生账务及File故障入口另作定向预检，完成前不启动全量。用户要求整体检查后，两路独立审查没有确认第二处同类P1/P2；不据此宣称不存在其他漏洞。

为避免panic的statx诊断再次挂起，采集器增加显式opt-in RINGWIN_CAPTURE_ABORT_ON_CRASH=1，命中实际thread panic或segfault标记即终止本次直接子进程，保留原始日志和fatal_diagnostic并返回失败；最终审计拒绝fatal结果。Windows和Linux各三个真实子进程探针分别验证panic、segfault快速失败及普通NativeAsset负向不误杀。生产进程、线上操作及交易行为未改变。后续新冻结使用ReleaseSafe256MiB/Debug512MiB runner，并对244f3ae7完整重验；旧6cd51582的成功不登记为新源码的通过。
