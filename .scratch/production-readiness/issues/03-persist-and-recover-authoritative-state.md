# 从真实磁盘日志与快照恢复一个 TradingShard

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [01 冻结首个 Linux 生产合同与 schema](01-freeze-linux-production-contract.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何在目标 Linux 文件系统上使 RawIngress、权威决策日志、快照和关键控制屏障真正可持久化，
并在进程崩溃、断电或 I/O 失败后恢复相同 AuthoritativeTradingState？

## What to build

建立一个深的 DurableStore 模块，保留现有稳定 record/snapshot codec，但把内存数组替换为真实
segment、manifest 和原子快照发布。调用者只需要 append、提交关键屏障、seal/rotate、发布快照
和 recover；同步策略、文件布局、校验、截断恢复与 I/O 错误处理封装在 implementation 内。

## Acceptance criteria

- [x] 两个实际 adapter 通过同一 interface：内存测试 adapter 与 Linux 文件 adapter；调用者不接触文件细节。
- [x] RawIngress、分片决策日志和控制事实按权限域与 StreamIdentity 分离，序号、内容哈希和 segment manifest 完整。
- [x] 普通日志写入 segment；关键控制/版本事实在 `commit` 返回前完成文件与 manifest 同步提交。
- [x] 快照在同一文件系统执行临时写、文件同步、原子替换和目录同步，并绑定已 seal 的精确 barrier。
- [x] 启动只接受完整 manifest、快照和连续日志尾；损坏、冲突、缺段或未知 schema 保持 RecoveryOnly。
- [x] fault injector 覆盖短写、EINTR、ENOSPC、EIO、只读、同步超时、截断、重排和损坏，并验证 SafetyGate 关闭。
- [ ] 目标文件系统上的真实 kill 与随机断电/重启试验；目标节点和文件系统仍未在 map 中指定。
- [x] stable snapshot bytes、segment digest、barrier 和恢复游标在 adapter 重开后保持一致；TradingShard 继续通过现有 snapshot codec 校验 CanonicalStateDigest、订单、账本、仓位、RiskReservation、Unknown。
- [x] 持久化延迟或错误关闭 SafetyGate，不由遥测或重试掩盖失败。

## Out of scope

- 旧开发 schema 迁移、网络文件系统、对象存储或数据库替代日志。
- 在没有目标机测量证据时预先引入 io_uring 专用实现。

## Answer

已新增 `src/durable_store.zig`。`Store` 是调用者唯一接口，提供 `append`、`commit`、`seal`、
`rotate`、`publishSnapshot` 和 `recover`；`MemoryAdapter` 用于确定性测试，`LinuxFileAdapter`
使用真实 Linux segment 文件和 manifest。三类 stream 通过 `StreamIdentity` 分离，manifest 保存
序号范围、提交 barrier、长度和 SHA-256 摘要。

关键提交会同步 segment 文件和 manifest；快照先写同目录临时文件并同步，再 atomic rename，最后
同步目录。启动恢复只接受完整 manifest、校验通过的快照和连续尾；结构损坏、schema 不兼容、
manifest 冲突或 I/O 故障进入 `RecoveryOnly` 并关闭 SafetyGate。合法 crash tail 由既有
`journal.Reader` 截止在最后完整 record。

目标 Linux 文件系统的断电、随机 kill、磁盘性能和真实生产资格尚未执行；WSL1 仅作为原生 ELF
文件路径回归环境，目录 fsync 使用明确的兼容回退，不作为目标耐久性证据。

2026-09-07 修复复核：segment 更新改为同目录临时文件原子替换，未提交追加不会先截断已提交
前缀；manifest schema 2 的 CRC32C 覆盖完整 entries。rotate 只允许在当前 segment 已 seal 且精确
barrier 快照已发布后执行，因此恢复接口不会静默跳过多个未被快照覆盖的 segment。

## Evidence

- [x] Windows Debug 全量测试 `193/193`；ReleaseSafe 同一目标随后复核。
- [x] WSL Linux `x86_64` ReleaseSafe ELF 执行 `--durable-store-test` 通过：raw/decision/control
  三个 stream，commit barrier=1，atomic snapshot，manifest 校验，关闭后重开恢复 `ready`。
- [x] 内存适配器 fault matrix 覆盖 short write、EINTR、ENOSPC、EIO、只读、sync timeout、truncate、
  reorder 和 corruption，所有错误均使 gate 关闭。
- [ ] 目标文件系统 kill、随机断电、RPO/RTO、真实 CanonicalStateDigest 资格和生产性能：待目标节点、
  文件系统与磁盘清单冻结后执行。
