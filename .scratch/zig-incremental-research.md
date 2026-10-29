# Zig 增量编译调查

日期：2026-10-28。适用本仓库固定版本 `0.17.0-dev.315+5b647b792`，Windows。本文为调查笔记，不是 issue/spec。

## 结论

可以使用增量编译，但要区分三层：已有产物缓存、常驻编译器的语义分析增量、后端和链接阶段的增量。添加一个开关不等于整个构建链都只重编修改的函数。对于当前 ReleaseSafe 验收，LLVM 生成目标文件的耗时仍可能保留，实际收益必须测量。

## 官方依据

- **产物缓存已存在。** 官方构建文档说明 `.zig-cache` 保存可加速后续构建的文件；无变化时复用产物与修改源码后的细粒度增量是不同机制。[构建系统文档](https://ziglang.org/learn/build-system/#installing-build-artifacts)
- **本版本增量默认未启用。** 固定提交的 `Config.Options.incremental` 默认是 `false`；`main.zig` 在启用增量时选择 `.incremental` 缓存模式，否则可选择 `.whole`。[Config.zig](https://github.com/ziglang/zig/blob/5b647b792/src/Compilation/Config.zig#L106)、[main.zig](https://github.com/ziglang/zig/blob/5b647b792/src/main.zig#L3436)
- **官方开发循环是 `zig build -fincremental --watch`。** `--watch` 保持构建会话以响应文件变化，增量语义分析可复用编译器状态；不能把反复启动一次性命令等同于常驻会话。官方 2026-04-08 日志推荐这组参数。[官方日志](https://ziglang.org/devlog/2026/#incremental-compilation-with-llvm)
- **LLVM 已支持增量编译，但仍需 LLVM Emit Object。** 同一日志确认 LLVM 后端已接入增量，减少 Zig 编译器侧的工作；LLVM 目标文件生成并未因此成为增量。因此“LLVM 不支持增量”的旧资料已经过时。编译错误反馈通常获益更多，成功构建收益取决于阶段占比。[官方日志](https://ziglang.org/devlog/2026/#incremental-compilation-with-llvm)
- **Windows 文件监视有源码实现。** 固定提交的 `Build/Watch.zig` 从第 289 行开始有 `.windows` 分支，调用 `NtNotifyChangeDirectoryFileEx` 并追踪变化文件。它证明监视实现存在，不证明当前项目的 Windows/COFF、LLVM、ReleaseSafe 全链路已经通过验收。[固定版本 Watch.zig](https://github.com/ziglang/zig/blob/5b647b792/lib/std/Build/Watch.zig#L289)
- **不能照搬 Linux 的毫秒级数字。** 官方新的 ELF 链接器案例明确限定 x86_64 Linux；它不能用作 Windows/COFF 的速度或可用性证据。[官方开发日志的 ELF 链接器条目](https://ziglang.org/devlog/2026/)

## 本仓库现状

- `python/verify_strategy_host.py:37-79` 使用多个独立的 ReleaseSafe 命令，并由 `tools/zig-entry.py` 调用固定入口；没有传入 `-fincremental`，也没有常驻监视会话。
- `tools/zig-entry.py:40-57` 已按 `source-N` 复用稳定的入口选项路径；没有证据表明它每次随机生成新路径导致缓存必然失效。
- `src/entry.zig:3` 通过编译期选择导入一个入口，`src/strategy/strategy_host_gateway.zig:3` 导入 TradingShard。此前称其为“网关全仓编译”不准确，更准确是“网关入口及其依赖的构建”。

## 建议与验证边界

保留现有产物缓存；开发反馈可另行验证受支持的 `-fincremental --watch` 会话。ReleaseSafe 完整验收仍需保留。先在固定工具链、相同目标和配置下比较冷构建、无变化重跑、修改单个函数后的常驻重建，再决定是否调整入口工具。

本次仅查阅官方文档、固定提交源码和本地脚本，没有修改构建工具、技能或源码，没有运行耗时编译、提交或交易。未测量 Ringwin 的增量收益，也未确认 Windows/COFF 的完整增量编译链可用；不能据此承诺把数分钟降低到毫秒。
