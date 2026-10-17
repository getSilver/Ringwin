# Frontier 11 Spec review

最终候选：冻结 HEAD `1c7e51caaaceff0b64d1463e841d39eacee5c2d8`，基点 `b6df712c9d22a8c2bc260de160406e421c497042`。源码清单 115 份、SHA256 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`。依据票 11:19–23、地图、capacity-contract、CONTEXT 及 ADR 0004/0010 审查，最终证据为 `11-final-v6-*`，不沿用 v1–v5 的未完成验收。

Spec：无剩余确认 P1/P2；票 11 的小规模 Linux/WSL 文件功能证据满足约定范围。原导出路径、目录 fsync 句柄及测试读取未初始化尾部问题均已修复并通过最终 Debug。此结论不授予目标 Linux 或生产资格。

- 票 11:19：独立重新计算当前源码身份、检查全部冻结 producer，验证 13 个 capture 的退出状态、无 timeout/fatal/drift、原始日志及内存采样文件摘要，以及四份实际 ELF 摘要。ReleaseSafe/Debug 均为 623 passed、1 skipped、0 failed；唯一 skip 是 WSL1 memfd_create ENOSYS 对应的精确 IPC 用例。两模式均在 WSL 实际执行，交叉构建没有充当运行证据。应用与 CLI 各 30 个新进程、十轮归档/恢复；业务与 500 组合观察夹具经验证函数核对，全片 live/terminal 各不超过 100。
- 票 11:20：独立逐项验证两套 11 对业务报告、观察报告及共享账户权威相等，覆盖余额、库存、费用、账本、占用、游标、历史根和 CanonicalStateDigest；恢复 sends 与 recovery_send_count 均为零。两套各有持久应用前/后 SIGKILL 及旧/新完整状态恢复，另各有 artifact 拒绝及六项 not_run。故障日志逐模式保留 18 项 passed，合计 36，两个 IPC skips 单列。独立在 WSL 对两套各五个保留数据集重新扫描全部文件，路径、长度、SHA256 均与末次记录相符；分配量不作为内容身份。
- 票 11:21：独立验证源码 ZIP 全部 130 个成员及摘要。identity/workload/samples/faults/summary 和四产物记录齐全；OS、lxfs、schema、种子、命令及输入规模可追溯。最终 `11-final-v6-audit.json` 为 84 checks passed；交接包区分历史失败和当前结果，未抹除失败、skip 或未执行项。
- 票 11:22：真实应用 strace 记录四片与 Coordinator 的成功目录 fsync，失败 syscall 为空、全局 sync fallback 为零；同步、发布及恢复继续失败关闭。样本 RSS、逻辑日志增长、恢复耗时和末端队列保留；OS 峰值不可用、分配量 partial/mutable、瞬态队列高水位及实际栈峰值未测。千单、压力、资源预算、索引成本和目标性能保持 deferred，不能称达标。
- 票 11:23：仅自有离线数据与子进程，未进行交易、凭证或目标机断电操作。WSL1/lxfs 结果不替代目标文件系统耐久性、外部 NodeFence、转储保护或完整生产资格；独立 Linux 功能交接可以完成，票 12 另行执行。
