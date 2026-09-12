---
status: accepted
date: 2026-09-11
---

# StrategyHost 数据面使用 Zig 校验的匿名 pipe

StrategyHost 不再把共享内存句柄、文件描述符、指针、映射大小或原子游标交给 Python。HostSupervisor 通过两条匿名单向 pipe 复用统一的有界版本化 framing：StrategyHostControlChannel 负责生命周期、恢复和 checkpoint；数据帧负责 input batch 与 strategy output。Zig 在边界校验会话、序列、容量、cursor、CRC 和 payload schema，Python 只持有自有 `bytes`，其输出仍须由 TradingShard 转换并授权，不能成为权威交易命令。

该决定取代 CONTEXT 中旧 StrategyHostAtomicBridge 的共享内存 C ABI 设计。Zig 内部可继续使用 sealed ring，但该 ring 不是 Python 子进程能力，也不是产品数据面的跨进程合同。

因此，旧设计要求恶意 Python 对 engine backing object 执行 `mmap`、`ftruncate` 或重映射的验收不再适用：没有 backing capability 就没有可执行这些操作的产品路径。替代验收启动真实 hostile child，核对唯一 argv 合同，并在 Linux 运行时核对 `/proc/self/fd` 不含 `qsh-ring`；Zig 同时确认握手前后 intent/confirmation 权限未开放。Windows 离线波次不等同于 Linux 运行态资格，Linux runtime 继续记为 `not_run`。
