# Frontier 11 Standards review

审查基点：`b6df712c9d22a8c2bc260de160406e421c497042`。审查候选：`07058de84153b145f3f75c306586c45e6877c507` 加十九处临时目录选项修复；源码清单 SHA256 已独立核对为 `ad5437cd40ac9534ae6d8de815237aeb4e46d0df3279748342274b070002a5cf`。包含 `f007fc16`、`73b882f1` 与目录同步、真实 adapter 探针及证据导出修复。仅审查代码与采集器；实际最终验收尚待 v2，本结论不表示套件或生产资格通过。

Standards：0 个确认问题，0 个必要建议。

- 依据 `docs/adr/0004-durable-store-persistence-contract.md` 的唯一持久化 seam、同步发布与故障关闭合同，`src/durable_store.zig:1015` 和 `:1023` 在 Linux 获取可同步目录 fd；`:1864` 不再将 BADF 静默解释为 WSL fallback。历史长度的私有同步 handle 在 `:1843` 使用 lseek 并恢复偏移，发布与恢复继续经既有 gate 关闭路径传播错误。
- 独立复核固定标准库 `std/testing.zig:648` 与 `std/Io/Threaded.zig:5290`：tmpDir 默认选项产生 O_PATH，直接借用其句柄的旧夹具同样需要可同步目录。`src/durable_store.zig:1906` 起十七处及 `src/demo_authority.zig:1427`、`:1474` 两处均仅将 tmpDir 选项改为 iterate=true；未改变测试断言、故障注入或业务逻辑。全 src 目录赋值检索未发现其他本轮 Linux 写入夹具遗漏。
- 依据 ADR 0010 的独立平台证据与资格边界，`src/file_acceptance_runtime.zig:18` 的线程包装仅用于离线文件入口；`.scratch/core-continuous-capacity/11-test-runner.zig:37` 与固定 Zig 标准 runner 的差异仅为 main 线程包装，原测试遍历、Skip、错误日志与 allocator leak 检查保持。Windows/Linux 复用公共业务夹具未将 Windows 通过当作 Linux 通过。
- `probe-11-adapter.py:22` 跟踪真实应用的 fsync/rename/sync，`:28` 要求四片及 Coordinator 目录均有成功 fsync，拒绝失败 syscall 或全局 sync 回退。`audit-11-final.py:60` 将探针源码/ELF 身份及原始日志摘要纳入最终审计。WSL1、断电、资源不可用及目标机资格边界明确保留；导出使用明确 WSL 路径。
- 依据 ADR 0009、0011、0013–0016，变更保留完整 CanonicalStateDigest、历史承接及恢复 seam，未以经济摘要或驻留计数替代恢复权威，也未新增发送许可。未发现需报告的 baseline smell；工具可检查项不列为人工 Standards 发现。

已按 `AGENTS.md`、`CONTEXT.md`、`docs/agents/domain.md` 与 `docs/agents/issue-tracker.md` 审查。最终冻结验收结果、Spec 审查及目标 Linux 资格由各自证据另行判断。
