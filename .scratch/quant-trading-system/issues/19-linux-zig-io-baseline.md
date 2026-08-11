# 确定 Linux、Zig 与 io_uring 生产基线

Type: research
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

为实现已确认的 io_uring、CPU 隔离、硬件时间戳和 Zig/C 互操作，第一版生产节点应固定哪些 Linux 内核、Zig、liburing、编译器及硬件能力基线？

## Answer

第一版固定为 Debian 13 x86-64 裸金属、发行版最新 Linux 6.12.y LTS 安全内核、Zig 0.17.x + `zig cc`、静态固定 liburing 2.15。Zig 编译器必须固定到通过资格验证的精确版本与提交，不跟随 nightly 浮动升级。节点至少 12 个物理核心，其中 4 个完整核心通过 cgroup v2 cpuset 与 `nohz_full` 专供 TradingShard；NIC 必须提供 MSI-X/RSS、PHC 和 RX/TX 硬件时间戳。

每个 I/O 线程独占一个 `SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG` ring，接收使用 multishot `recvmsg` + provided buffers；启动时实际探测并 smoke-test 所需能力。首版不启用 SQPOLL、IOPOLL 或 zero-copy，所有工具链、内核、驱动和固件升级都须重跑 ABI、确定性回放与完整负载延迟测试。

完整证据和节点准入清单见[研究记录](../research/19-linux-zig-io-baseline.md)。其中关于 Zig 0.16.0 的版本选择已由 2026-07-27 的 Zig 0.17 决策取代；其余 Linux、liburing、ABI 与节点资格验证结论继续有效，Zig 0.17 的正式候选版本需重跑同一资格验证。
