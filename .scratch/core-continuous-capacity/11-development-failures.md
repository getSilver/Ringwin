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
