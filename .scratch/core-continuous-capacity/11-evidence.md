# 11 Linux 文件持久化与持续恢复证据

2026-10-17。最终v6验收与封存审计通过；本页区分开发失败和新冻结源码的实际结果。

## 范围和身份

本票验证WSL1/lxfs上的真实Linux文件功能，独立于票10的Windows结果。固定Zig `0.17.0-dev.315+5b647b792` 在Windows构建x86_64-linux ELF，再由WSL实际运行；交叉编译本身不算通过。当前115份源码及build文件摘要为 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`，冻结前HEAD为 `1c7e51ca`，最终新流水线为 `11-final-v6`。journal/state/registry为39/43/37，Core artifact identity为1，合成种子为0x20261008；artifact身份与实际ELF SHA分别检查。

本机Ubuntu20.04.3、kernel4.4.0-17763-Microsoft、UID1000。业务数据、进程终止副本、测试cwd及临时文件位于 `/home/ubuntu/ringwin-frontier11` 的lxfs；源码和封存日志位于drvfs。完整mount options、OS/CPU/内存、权限、栈限制及普通目录探针见[宿主记录](11-linux-host.json)。WSL虚拟文件系统不提供真实目标ext4/xfs设备/驱动拓扑资格。

## 实现与公共业务链

复用原票09/10的Owner、TradingShard、Gateway、Store与快照恢复夹具，保留legacy Windows模块名以保持已有入口和证据引用；新增两个Linux离线应用入口 `--linux-capacity-file`、`--linux-observation-file`。没有新控制面或交易协议。

LinuxFileAdapter增加caller-owned initLinux；历史长度使用私有同步handle的lseek并恢复原偏移，避开旧WSL1缺失的statx；无history objects时通过no-follow open区分根不存在和真实错误。Linux两种初始化均打开可同步的目录fd，修复O_PATH导致fsync(dir)=EBADF的问题；BADF现在失败关闭。17个Store和2个Owner旧夹具的借用目录同步使用iterate=true，没有删除断言或放宽恢复合同。

主进程硬栈上限8MiB，--stack不能提高其hard limit。仅离线file CLI使用64MiB工作线程；完整测试保留固定标准runner全部测试、错误日志和allocator leak检查，ReleaseSafe用256MiB、Debug用512MiB线程执行原main body。[256MiB来源](11-test-runner-origin.json)和[512MiB来源](11-test-runner-512-origin.json)分别绑定原始/修改后SHA。生产role入口未使用该包装；实际线程峰值栈未测。

主文件链包含四片不同归属、共享账户ceiling、部分成交经济/费用/账本/占用、待撤、终态、accepted和Unknown。每轮按durable next-order/next-command推进归档，不重置序号。恢复比较全部报告权威字段及CanonicalStateDigest，保持经济和账本摘要；不能用semantic/economic摘要替代完整恢复身份。

另一个File夹具通过同一公共Owner/Gateway链实际执行500个Venue×产品×Instrument组合、四Venue路由、三类合成策略与独立风险。每个夹具跨全部分片live/terminal各不超过100；观察组合不扩大订单规模。千单/压力和预算资格始终deferred。

## 开发回归与失败保留

[开发失败说明](11-development-failures.md)记录WindowsRequired、8MiB栈溢出、statx、Windows worktree路径、producer漂移、O_PATH和旧夹具失败；原始日志、result、旧ELF和物理数据保留。v1冻结源码zip及应用半程结果保留；它因旧夹具修复触发source漂移保护停止，未启动完整ReleaseSafe/Debug。不能把原v1候选的成功步骤承接为最终通过。

Linux公共文件定向8/8通过；共享Windows定向8/8属于Linux-only目录修复前的开发源，不能冒充最终Linux源码套件。目录句柄公共Store回归实际red DirectorySyncFailed→green1/1，Owner90种文件中断组合所在指定用例1/1通过。v2应用30进程通过后暴露allocation观测误当内容身份的审计错误；3条定向回归和真实五数据集回放确认修复，内容冲突仍拒绝。

v3两组应用/CLI各30进程及物理审计通过，但完整ReleaseSafe在旧IPC测试memfd ENOSYS和旧OKX测试64MiB worker栈溢出失败，panic诊断未退出，外层10800秒timeout终止；Debug未启动。直接模块定向复现后，仅测试入口对memfd ENOSYS明确SkipZigTest，其他错误仍失败；生产IPC未改。两个旧测试worker改为256MiB，Linux内存Owner定向1/1、Windows内存及文件Owner分别1/1通过，原断言和业务逻辑不变。新source 6cd51582另以v4冻结；不承接v3为最终全量通过。

v4同源ReleaseSafe实际623通过/1 skipped/0失败；Debug84项撞256MiB栈guard，独立定向只增加测试runner到512MiB后通过。v5为明确复用成功记录的续验，但Debug316项旧账户投影全对象比较读取未初始化tagged union尾部而panic，仍未通过。修复仅在测试比较所有元数据、计数及有效前缀，完整authority/digest断言保留；新source244f3ae7的直接用例Debug与ReleaseSafe各1/1，整个私有成交恢复模块及依赖Debug322通过/1 skipped/0失败；原生账户连续性2/2、经济对账15/15、多Venue账务9/9、Linux File故障回归8/8含18场景全部通过，源码/producer均无漂移。两路审查无剩余确认P1/P2，实际原始失败及次生诊断挂起均保留。

采集器显式opt-in的fatal标记监测已在Windows/Linux各通过三个真实子进程探针：panic/segfault及时终止本次owned child、普通NativeAsset容量负向不误触发。命中后保留日志与fatal_diagnostic并返回失败，最终审计拒绝该结果。v6重新冻结新源码与15个producer，重建应用/CLI、60个新业务进程和两套完整测试；旧6cd51582的通过仅作历史，不登记为本轮新源码验收。

普通Python目录探针成功与实际adapter句柄不是同一证据。旧真实adapter strace暴露EBADF+全局sync；v4冻结应用probe实测四片及Coordinator目录共951次fsync成功，无失败syscall、无global sync fallback，并绑定ELF和日志哈希。详见[文件语义](11-file-semantics.md)。

## 最终v6验收与独立交接

[最终审计](11-final-v6-audit.json)84项通过；[独立Linux交接包](11-final-v6-linux-evidence/summary.md)已封存。115份源码及15个producer的[冻结源码ZIP](11-final-v6-source.zip)共130项逐一核对SHA，编译器、源码、四个ELF与实际消费身份一致。十三个最终capture退出0、无timeout/fatal、source和producer漂移均为0。

| 验收 | 新冻结源码实际结果 |
| --- | --- |
| 完整ReleaseSafe | 623 passed / 1 skipped / 0 failed；3174.243秒 |
| 完整Debug | 623 passed / 1 skipped / 0 failed；6762.339秒，22:14完成 |
| 应用 / CLI | 各十轮、30个实际Linux新进程，含500组合与三类别、共享账户和两次受控SIGKILL恢复 |
| 实际文件审计 | 两组各五数据集的完整路径/长度/SHA、全部报告authority和零重发核对通过 |
| 故障 / 格式身份 | 两模式各18项故障及拒绝；真实adapter目录fsync共951次成功、零失败、零全局sync回退 |
| 独立审查 | [Standards](11-standards-review.md)与[Spec](11-spec-review.md)，无剩余确认P1/P2 |

两套唯一skipped均为`strategy_host_ipc.test.bounded rings and frozen bridge fail closed`：本机WSL1的memfd_create返回ENOSYS。生产IPC仍失败关闭；该IPC能力不计作已验证。Windows-only旧用例在Linux返回的测试项也不作为Windows平台证据。本票不以623个通过推导全部生产能力。

交接包59项fault/observation记录分别为41 passed、2 rejected_before_launch、2 skipped、12 not_run、1 not_measured、1 partially_measured。不能将59称为59个通过案例；hook失败与真实SIGKILL、物理破坏、已认证错误格式及ELF启动前拒绝分别列示。v1–v5失败、未执行项、原源码ZIP、原始结果及其SHA均保留。

| 小功能资源观察 | app | CLI |
| --- | ---: | ---: |
| 100ms采样直接子进程RSS最大值，bytes | 274903040 | 274907136 |
| 主链初始 / 十轮后logical bytes | 6107476 / 7920172 | 6107476 / 7920172 |
| 十轮后allocated bytes聚合 | null，缺项 | null，缺项 |
| recover整命令elapsed范围，秒 | 3.239–3.807 | 3.272–3.463 |

原始样本见[resources](11-final-v6-linux-evidence/resources.json)与[samples](11-final-v6-linux-evidence/samples.jsonl)。以上是功能样本观察，不是预算、吞吐、apply/commit/p99、瞬态队列高水位或实际线程栈峰值。OS峰值RSS在本机不可用；allocation可缺失或独立于内容变化，原始观察仍全部保留。

| 票11条目 | 直接证据与范围 |
| --- | --- |
| 小规模真实File及新进程业务恢复 | 两个实际ELF各30新进程，所有夹具live/terminal全片各不超过100，十轮保留单调身份；观察组合不扩大订单规模 |
| 故障、完整authority与零重发 | 完整余额/库存/成本/费用/账本/占用/游标及CanonicalStateDigest，36个故障拒绝场景、发布前后owned SIGKILL、accepted/Unknown零重发 |
| 身份、资源、失败保留 | host、schema、种子、115源码/15producer、四ELF、逐命令/PID/时间、raw结果和失败源码ZIP、59项分类观察 |
| 文件恢复语义及独立Linux交接 | [文件语义](11-file-semantics.md)、实际adapter syscall日志、独立证据包；WSL1/lxfs功能，不授目标ext4/xfs/掉电/性能资格 |
| 操作与资格边界 | 全部离线合成夹具及自有进程，无部署/网络交易/凭证；资源/压力、外部NodeFence、dump与生产资格未取得 |

## 最终验收入口和边界

复现须在相同工作树、固定Windows Zig和该WSL发行版执行 `python .scratch/core-continuous-capacity/run-11-final.py <new-prefix>`；只接受新prefix，不覆盖旧结果。应用与CLI各十轮/30新进程后才运行完整ReleaseSafe与Debug；全部阶段冻结源码/producer、绑定ELF SHA。随后执行 `python .scratch/core-continuous-capacity/audit-11-final.py <new-prefix>`，再执行 `python .scratch/core-continuous-capacity/seal-11-evidence.py <new-prefix>`。所有逐命令参数和耗时见result.json。

数据目录在lxfs保留，native审计重新哈希实际物理文件，再导出只含identity/workload/samples/faults/report/每进程命令、PID、stdout/stderr和文件清单的证据包。存储hook、物理文件破坏、合法CRC的错误身份和真实SIGKILL分别报告；hook不称真实磁盘ENOSPC/short-write/EIO/timeout。进程终止只发生在持久应用前后明确marker，不称syscall内随机断电或跨分片原子事务。

/proc/PID/status每100ms采样直接子进程RSS。WSL1 VmHWM=0按不可用处理，st_blocks=0按allocated bytes=null处理；不把0或Python/WSL父进程RSS冒充真实应用峰值。logical bytes和文件SHA可测。recovery_ns仅Owner恢复片段，result elapsed为完整进程/命令wall time；队列仅命令末尾resident样本。实际栈峰值、瞬态队列水位、物理索引成本、apply/commit p99和所有资源/容量预算均未测或deferred。

真实目标磁盘掉电、随机syscall中断、凭证/dump、真实NodeFence、目标平台性能及Linux生产资格未运行或未取得。不部署、不进行Demo/Testnet/生产下单、不访问凭证。WSL1功能证据不关闭production-readiness专项。用户已授权票11完成后继续票12；本证据仅覆盖11，不提前关闭12。
