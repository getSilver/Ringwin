# Linux、Zig 与 io_uring 第一版生产基线

研究日期：2026-07-25

## 结论

第一版固定为一套保守、可复现且已经覆盖所需能力的组合：

| 项目 | 生产基线 | 选择理由 |
|---|---|---|
| 部署形态 | x86-64 裸金属、单路 NUMA 优先 | CPU、IRQ、NIC 队列和 PHC 所有权可验证；不把共享虚拟化噪声带入首版 |
| 发行版 | Debian 13 `trixie` stable，安装当日全部安全更新 | Debian 13 原生提供 Linux 6.12 LTS、GCC 14.2、glibc 2.41，并承诺五年支持；不需要自维护发行版分叉。[Debian 13 发布公告](https://www.debian.org/News/2025/20250809) |
| 内核 | Debian 的最新 6.12.y 安全内核；镜像清单记录精确包版本 | 6.12 是上游 longterm 分支，预计维护至 2028-12；已经覆盖本系统所需 io_uring 能力。[kernel.org 活跃版本](https://www.kernel.org/releases.html) |
| Zig | 精确固定 Zig 0.16.0 官方 x86_64-linux 包及签名/哈希 | 0.16.0 是研究时的稳定版，`x86_64-linux` 为 Tier 1；禁止使用 master/nightly。[官方发布下载](https://ziglang.org/download/)、[0.16.0 发布说明](https://ziglang.org/download/0.16.0/release-notes.html) |
| C 编译器 | 生产构建只使用 Zig 0.16.0 自带的 `zig cc`（Clang 21.1.8）；GCC 14.2 仅作 CI 交叉验证 | 减少生产构建工具链数量；Zig 官方说明 0.16.0 的 `zig cc` 基于 Clang 21.1.8，Debian 13 的系统 GCC 为 14.2。[Zig 0.16.0 工具链说明](https://ziglang.org/download/0.16.0/release-notes.html#Toolchain)、[Debian GCC 包](https://packages.debian.org/trixie/gcc) |
| liburing | 静态固定 liburing 2.15 tag / commit `d41bf92` | 2.15 是研究时最新正式版，并修复 `recvmsg_validate()` 整数溢出等直接相关问题；liburing 官方说明用户态库与某个内核版本并不绑定，真正能力仍须运行时探测。[liburing 2.15 官方发布](https://github.com/axboe/liburing/releases/tag/liburing-2.15)、[liburing 官方 README](https://github.com/axboe/liburing) |
| PTP 工具 | Debian `linuxptp` 4.2、`ethtool` 6.14.2 | 与发行版一起更新，提供 `ptp4l`、`phc2sys` 和 NIC 时间戳能力检查。[Debian linuxptp](https://packages.debian.org/stable/utils/linuxptp)、[Debian ethtool](https://packages.debian.org/stable/net/ethtool) |

不选择更新的 Linux 6.18，并非它不能工作，而是首版没有任何已确认需求依赖其新增接口。liburing 很薄且 2.15 包含与 `recvmsg` 相关的正确性修复，因此固定官方源码并静态链接；不同时依赖 Debian 的 2.9 动态库。后续升级只能由缺陷修复、硬件支持或端到端基准触发。

## 1. Linux 和 io_uring 能力合同

### 1.1 内核构建与启动前提

生产镜像必须验证以下内核配置，而不是只检查 `uname`：

- `CONFIG_IO_URING=y`
- `CONFIG_CPUSETS=y`
- `CONFIG_NO_HZ_FULL=y`
- `CONFIG_PTP_1588_CLOCK=y`
- 目标 NIC 的驱动与硬件时间戳支持

6.12 足以支持当前热路径：

- ring 的唯一提交线程使用 `IORING_SETUP_SINGLE_ISSUER`，该能力自 6.0 提供。
- `IORING_SETUP_DEFER_TASKRUN` 自 6.1 提供；首版与 `IORING_SETUP_TASKRUN_FLAG` 一起启用。它要求同一提交线程定期调用 `io_uring_enter(..., IORING_ENTER_GETEVENTS)` 或等待函数，否则 completion 会停滞，因此必须有进度 watchdog。
- multishot `recv`/`recvmsg` 自 6.0 提供；每个 CQE 都必须检查 `IORING_CQE_F_MORE`，清零后重新挂载。
- ring-mapped provided buffers 自 5.19 提供，官方建议优先于旧式 `provide_buffers`。
- buffer ring 耗尽会以 `-ENOBUFS` 结束 multishot；实现必须补充 buffer、标记过载指标并重新挂载，不能把停止接收当成空闲。

这些版本和约束来自 liburing 的 [io_uring_setup(2)](https://raw.githubusercontent.com/axboe/liburing/liburing-2.14/man/io_uring_setup.2)、[multishot recvmsg 手册](https://www.man7.org/linux/man-pages/man3/io_uring_prep_recvmsg_multishot.3.html) 和 [官方 networking 说明](https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023)。

首版每个 I/O 线程独占一个 ring，不跨线程提交；网络 ring 与日志 ring 分开。ring flags 固定为 `SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG`。网络接收使用 multishot `recvmsg` + provided-buffer ring，以便同时取得 payload 与 `SO_TIMESTAMPING` ancillary data。订单发送报文较小，先用普通 `sendmsg`；不启用 send zero-copy。

首版明确不启用：

- `IORING_SETUP_SQPOLL`：官方手册明确要求逐用例评估，不能把它视为自动“更快”；它还占用轮询内核线程。[io_uring_setup(2)](https://raw.githubusercontent.com/axboe/liburing/liburing-2.14/man/io_uring_setup.2)
- `IORING_SETUP_IOPOLL`：该模式面向支持轮询的存储/O_DIRECT，不是普通 TCP 网络路径。[io_uring_setup(2)](https://raw.githubusercontent.com/axboe/liburing/liburing-2.14/man/io_uring_setup.2)
- io_uring zero-copy RX、send zero-copy、NAPI busy-poll、固定文件表：只有独立基准证明 P99/P99.9 改善且缓冲区生命周期测试通过后再加。
- 自定义内核、PREEMPT_RT、DPDK/XDP：当前 10 μs 核心预算不依赖这些能力。

### 1.2 启动时探测，而非相信版本号

liburing 官方说明其版本与内核版本解耦，因此进程启动时必须：

1. 创建带 `SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG` 的 ring；失败即节点不合格。
2. 使用 `IORING_REGISTER_PROBE`/liburing probe 检查 `RECVMSG`、`SENDMSG`、`TIMEOUT` 和 `ASYNC_CANCEL`。
3. 实际注册一组 provided-buffer ring，并完成一次 multishot `recvmsg` 自检；multishot 是 `RECVMSG` 的模式，不能只靠 opcode probe 推断。
4. 要求 `IORING_FEAT_NODROP`，同时监测 CQ overflow；“内核通常不丢 CQE”不能代替有界 CQ 和过载处理。
5. 任何 `EINVAL`、`EPERM`、缺少 feature 或 buffer-ring 注册失败都使节点 fail closed，不静默退回另一条未经验证的 I/O 路径。

probe 的用途由 [liburing `io_uring_get_probe_ring(3)`](https://raw.githubusercontent.com/axboe/liburing/liburing-2.14/man/io_uring_get_probe_ring.3) 定义；CQ overflow 行为见 [io_uring_setup(2)](https://raw.githubusercontent.com/axboe/liburing/liburing-2.14/man/io_uring_setup.2)。

安全上设置 `kernel.io_uring_disabled=1`，把交易服务账号放入专用 `io_uring_group`；其他非特权进程不能创建 ring。Linux 官方 sysctl 文档说明值 1 会只允许 `CAP_SYS_ADMIN` 或指定组创建 ring，而值 2 会完全禁止创建。[Linux `io_uring_disabled` 文档](https://www.kernel.org/doc/html/v6.9/admin-guide/sysctl/kernel.html#io-uring-disabled)

交易进程本身保持非 root，不持有 `CAP_SYS_ADMIN`。NIC、PTP、IRQ 和 cgroup 配置由启动前的特权系统服务完成。registered buffers 所需的 memlock 限额通过服务管理器显式配置；liburing README 说明注册缓冲区会消耗 `RLIMIT_MEMLOCK`。[liburing 官方 README](https://github.com/axboe/liburing#ulimit-settings)

## 2. CPU 隔离基线

### 2.1 硬件与核心分工

首版节点至少提供 12 个物理核心：

- 4 个完整物理核心固定给 4 个 `TradingShard`。
- 至少 8 个非分片核心承担行情 I/O、执行 I/O、日志、全局风控、PTP 和 OS housekeeping；具体分配在进程拓扑票据中按压测收敛。
- 首版关闭 SMT；若以后开启，分片核心的 sibling 也必须保持空闲，不能把 sibling 当成额外容量。
- 单路 NUMA 优先；NIC、ring buffers、SPSC 和分片内存必须位于同一 NUMA node。多路机器只有在显式 NUMA 拓扑和跨节点基准完成后才合格。

Linux 官方 CPU isolation 指南强调，系统必须保留 housekeeping CPU，NUMA 系统最好每个 node 至少一个；`nohz_full` CPU 只能运行一个用户任务且不应执行系统调用。[CPU Isolation](https://docs.kernel.org/admin-guide/cpu-isolation.html) 这正是只运行单写者交易循环、把网络和磁盘移出分片核心的理由。

### 2.2 固定配置

分片核心采用以下三层隔离：

1. cgroup v2 `cpuset.cpus.partition=isolated` 建立可在运行时验证的独占调度分区；内核文档推荐它取代不灵活的 `isolcpus=domain`。[cgroup v2 cpuset partitions](https://www.kernel.org/doc/html/v6.12/admin-guide/cgroup-v2.html#cpuset)
2. 启动参数对分片核心设置 `nohz_full=<shard-cpus>`；默认 IRQ 目标使用 `irqaffinity=<housekeeping-cpus>`，managed IRQ 使用 `isolcpus=managed_irq,<shard-cpus>`。这是内核 CPU isolation 指南给出的完整隔离组合。[CPU Isolation 完整示例](https://docs.kernel.org/admin-guide/cpu-isolation.html#full-isolation-example)
3. 所有 NIC、NVMe、PTP kworker 和其他可移动 IRQ 都固定到非分片核心，并在启动后核对 `/proc/irq/*/effective_affinity_list`。Linux 暴露 `smp_affinity_list` 控制 IRQ 目标；irqbalance 可能覆盖手工配置，生产节点必须禁用它或设置 banned mask。[SMP IRQ affinity](https://docs.kernel.org/core-api/irq/irq-affinity.html)、[Linux 网络扩展指南](https://docs.kernel.org/networking/scaling.html#rss-irq-configuration)

NIC 使用硬件 RSS/MSI-X 把队列直接引到 I/O 核心。当每个硬件接收队列已经对应一个 CPU 时，RPS 通常是多余的，并会增加跨核 IPI；Linux 网络文档也给出相同建议。[Scaling in the Linux Networking Stack](https://docs.kernel.org/networking/scaling.html)

`nohz_full` 要求稳定可靠的 clocksource。节点验收必须确认当前 clocksource 为稳定 TSC，CPU 提供 constant/nonstop TSC，且内核没有回退到 HPET；Linux 文档说明不可靠 TSC 会破坏 full-dynticks 前提。[CPU Isolation](https://docs.kernel.org/admin-guide/cpu-isolation.html#full-dynticks-aka-nohz-full)、[x86 timekeeping flags](https://docs.kernel.org/virt/kvm/x86/timekeeping.html)

分片与 I/O 核心使用 CPUFreq `performance` 策略；内核文档定义该 governor 会请求策略允许的最高频率。[CPU Performance Scaling](https://docs.kernel.org/admin-guide/pm/cpufreq.html#performance) 不在首版全局禁用所有 C-state，而是用 PM QoS 约束和实际 wake-up 延迟决定是否关闭更深 idle state；每个 idle state 的 exit latency 由 sysfs 暴露。[CPU Idle Time Management](https://docs.kernel.org/admin-guide/pm/cpuidle.html)

## 3. 硬件时间戳与时钟基线

生产 NIC 必须同时具备：

- PCIe MSI-X、多队列/RSS。
- 关联的 PTP Hardware Clock，即 `/dev/ptpN`。
- RX/TX hardware timestamp 和 raw hardware timestamp 报告能力。
- 驱动可通过 `ethtool -T <dev>` 显示上述能力及关联 PHC；`ethtool -T` 的官方定义就是显示设备时间戳能力和 PTP 硬件时钟。[ethtool(8)](https://man7.org/linux/man-pages/man8/ethtool.8.html)

socket 使用 `SO_TIMESTAMPING_NEW`，请求 `SOF_TIMESTAMPING_RX_HARDWARE | SOF_TIMESTAMPING_RAW_HARDWARE`；时间戳从 `recvmsg` control message 读取。Linux 官方文档说明 `SO_TIMESTAMPING` 支持硬件源和流式 socket，并建议使用 NEW 接口避免旧时间结构的 2038 问题。[Linux Timestamping](https://docs.kernel.org/networking/timestamping.html)

时间同步使用：

```text
PTP grandmaster -> NIC PHC (`ptp4l -H`) -> CLOCK_REALTIME (`phc2sys`)
```

`ptp4l` 默认使用硬件时间戳；`phc2sys` 的典型用途是把系统时钟同步到已由 `ptp4l` 同步的 PHC。[ptp4l(8)](https://www.linuxptp.org/documentation/ptp4l/)、[phc2sys(8)](https://www.linuxptp.org/documentation/phc2sys/) 进程持续上报 PHC offset、frequency adjustment、丢失同步和 clock-step；超过后续按策略定义的阈值时，时间敏感策略停止开仓。

硬件接收时间戳只是“包到达本机 NIC”的时间，不是交易所事件发生时间，也不能消除公网 WAN 抖动。TLS/WebSocket 又是 TCP 字节流，分段、合并和重传意味着一个硬件包时间戳不天然对应一条业务消息；业务 `receive_time` 定义为“完成该帧所需最后字节”的接收戳，并另存 socket-read 的单调时间。Linux 文档专门说明了 bytestream timestamp 的这些关联限制。[Linux bytestream timestamps](https://docs.kernel.org/networking/timestamping.html#bytestream-timestamps) 它继续与 `source_time`、核心 `CLOCK_MONOTONIC` 和 UTC 日志时间分开保存。无 PHC 直通的云 VM 只能降级为软件时间戳，不符合首版生产低延迟节点资格。

## 4. Zig/C 互操作与构建基线

### 4.1 ABI 边界

首版直接通过一个专用 Zig 模块、一次 `@cImport` 引入固定在 2.15 的 `liburing.h`；Zig 文档建议应用通常只保留一个 `@cImport`，以避免重复翻译和 inline 函数重复。[Zig `@cImport`](https://ziglang.org/documentation/0.16.0/#cImport) 如果 0.16.0 的 C translation 无法稳定处理目标头文件，优先静态链接官方 `liburing-ffi.a`；liburing 官方说明该变体为不能消费 `static inline` 接口的语言导出全部定义。[liburing 官方 README](https://github.com/axboe/liburing#liburing-ffi) 不预建自研通用封装层。

系统自己的 Zig/C 公共 ABI 只允许：

- `<stdint.h>` 固定宽度整数、裸指针 + 长度、显式整数错误码。
- opaque handle，或字段明确的 C struct。
- Zig 侧使用 `extern struct`、显式 tag type 的 enum 和 C calling convention。
- 禁止 Zig slice、error union、普通 Zig enum、allocator 或所有权不明的指针穿过 ABI。

Zig 官方文档保证 `extern struct` 匹配目标 C ABI，普通 enum 默认不保证 C ABI，而显式整数 tag 的 enum 才兼容；`export` 函数使用 C ABI。[Zig extern struct](https://ziglang.org/documentation/0.16.0/#extern-struct)、[Zig C ABI 与 enum](https://ziglang.org/documentation/0.16.0/#extern-enum)、[Exporting a C Library](https://ziglang.org/documentation/0.16.0/#Exporting-a-C-Library)

构建必须生成并运行一个 ABI 自检，逐项比较 C `_Static_assert(sizeof/alignof/offsetof)` 与 Zig `@sizeOf/@alignOf/@offsetOf`。该检查覆盖所有跨语言结构；ABI 变化即构建失败。

### 4.2 优化与编译器资格

第一版生产构建默认 `ReleaseSafe`，因为 Zig 官方定义它为“优化开启、安全检查开启、可复现”；`ReleaseFast` 会关闭安全检查。[Zig Build Mode](https://ziglang.org/documentation/0.16.0/#Build-Mode) 只有在完整压测证明某个小范围函数的检查开销使性能合同失败后，才在该范围显式关闭 runtime safety，并保留等价溢出/边界测试。输入解析、金额、风控和订单状态机不关闭安全检查。

Zig 0.16.0 仍未达到 1.0。官方发布说明明确写出存在已知 bug、误编译和回归；其 LLVM 21 后端还因上游回归暂时禁用了 loop vectorization，预计到 0.18 才解决。[0.16.0 “This Release Contains Bugs”](https://ziglang.org/download/0.16.0/release-notes.html#This-Release-Contains-Bugs)、[LLVM loop vectorization 回归](https://ziglang.org/download/0.16.0/release-notes.html#Loop-Vectorization-Disabled-to-Work-Around-Regression) 因此版本“稳定”不等于可以跳过资格验证：

- 禁用实验性 incremental compilation。
- 同一提交用 Zig 0.16.0 重复构建并核对产物哈希。
- ABI/C 部分在 CI 额外用 Debian GCC 14.2 编译并运行相同测试。
- 对订单簿更新、定点乘除、风控和 SPSC 留下汇编/基准快照。
- 发布前执行确定性回放、asan/ubsan 测试构建、满功能容量测试和至少一次长时 soak。
- 任何 Zig、liburing、内核或 CPU microcode 变化都重新执行上述资格验证，不做原地“无测试升级”。

## 5. 节点准入清单

节点只有全部通过才可进入 active/standby 池：

1. OS 为 Debian 13 amd64，包和内核精确版本已写入不可变镜像清单，安全更新无欠账。
2. 内核配置项、io_uring feature probe、multishot + provided-buffer smoke test全部通过。
3. `kernel.io_uring_disabled=1` 且交易服务账号是唯一获准的非特权组；进程没有 root/CAP_SYS_ADMIN。
4. `cpuset.cpus.isolated` 恰好包含 4 个分片核心；每核只有一个 TradingShard；没有 IRQ、kworker 或 sibling workload。
5. NIC/NVMe IRQ 的 effective affinity 只落在 I/O/housekeeping 核心；RSS 队列无丢包、无 ring overflow。
6. `ethtool -T` 显示 PHC、RX/TX hardware 和 raw hardware timestamps；`ptp4l`/`phc2sys` 已锁定且 offset 在已校准阈值内。
7. clocksource 为稳定 TSC，CPU governor、NUMA placement、memlock 和预触页设置与基准环境相同。
8. 在真实 TLS/WebSocket 解析、日志、指标和风控全开的条件下，达到已确认的核心 P99 ≤ 10 μs、内部端到端 P99 ≤ 50 μs；同时记录 P99.9 和最大抖动。
9. 与最小 epoll 原型做一次同机 A/B；若 io_uring 没有达到或优于性能合同，保留架构接缝但不同时维护两个生产后端。

## 6. 延后项

- 不固定具体 CPU、NIC 和 NVMe 型号；采购前依据本文件的能力合同，用候选硬件实测后再出 BOM。
- 不现在决定 SQ/CQ 深度、buffer 数量、PTP offset 阈值、C-state 上限和 IRQ coalescing 数值；这些都依赖真实交易所连接与硬件测量。
- 不添加自研 io_uring 封装框架、通用 C 插件 ABI 或双 I/O 后端。已确认的单 ring/单 issuer、一次 `@cImport` 和有界缓冲池足够启动实现。
