---
status: accepted
date: 2026-09-06
---

# DurableStore 持久化与恢复合同

## Decision

- `src/durable_store.zig` 是 RawIngress、分片决策日志和控制事实的唯一持久化 seam；调用者只提交
  `StreamIdentity`、稳定 `journal.Record`、barrier 和已编码 snapshot，不接触文件名或同步 syscall。
- `MemoryAdapter` 只用于确定性测试；Linux 生产实现使用真实 segment 文件、二进制 manifest 和
  同文件系统的临时快照、文件同步、原子 rename、目录同步。
- manifest 记录 stream domain、identity、segment、序号范围、提交 barrier、长度和内容摘要；
  未知 schema、缺段、摘要冲突、快照损坏或非连续尾部只能返回 `RecoveryOnly`，不能猜测恢复。
- 普通 append 可留在 ReplayRPO 批次内；`commit`、`seal` 和快照发布完成同步后才可作为外部效果
  的持久屏障。任何持久化故障都关闭相应 SafetyGate。
- 目标 Linux 文件系统上的断电、随机 kill、性能和真实磁盘资格不由 WSL1 或离线测试推断；
  io_uring 仍需目标测量后再决定。

## Consequences

现有 stable journal/snapshot codec 不需要迁移层，TradingShard 继续负责语义验证和状态 digest。
持久化 implementation 可以替换而不泄漏文件布局；上线前仍必须在实际目标文件系统补做故障矩阵和
恢复资格证据。
