# Frontier 11 Standards review

审查基点：`b6df712c9d22a8c2bc260de160406e421c497042`。最终验收：`11-final-v6`，冻结 HEAD `1c7e51caaaceff0b64d1463e841d39eacee5c2d8`，115 个源码/构建文件的清单 SHA256 为 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`。

最终未发现未修复 P1/P2；Standards 0 个待处理问题。

- 按 `AGENTS.md`、`CONTEXT.md`、`docs/agents/domain.md`、`docs/agents/issue-tracker.md` 与 ADR 0004、0009–0011、0013–0016 审查。公共 Store、Owner/Gateway 及完整恢复摘要合同保持，Unknown 不因恢复获得发送许可。
- `src/durable_store.zig:1015`、`:1023` 为 Linux 打开可同步目录 fd，`:1864` 将 BADF 视为失败；历史长度用私有同步 handle 的 lseek 并恢复偏移。十九处直接借用临时目录的旧夹具均提供 iterate=true。实际 adapter 探针要求四片及 Coordinator 目录 fsync 成功、零全局 sync 回退，不能据此推断断电耐久性。
- 已修复 P2：旧 `venue_fill_recovery_acceptance.zig:433`、`:439` 的整对象比较读取 AccountProjection 未初始化的 seen tagged union。现 `:224` helper 比较全部元数据、计数与四数组有效前缀，保留公共状态一致性要求；未用生产状态清零或加栈掩盖此语义错误。最终 Debug 已通过原失败用例及完整套件。
- 两个固定 runner 保留原标准测试遍历、Skip、错误日志和泄漏检查；ReleaseSafe 测试线程 256 MiB、Debug 512 MiB，离线文件 CLI 64 MiB，均不改变生产线程预算。IPC 仅因原始 memfd_create 返回 ENOSYS 跳过；生产实现与其他断言保持。
- 采集器区分内容身份与可变 allocation 观测，保留原始资源字段。显式启用的崩溃捕获只终止自有直接子进程并记录 fatal_diagnostic，审计拒绝此类记录。v1–v5 失败证据保留；最终 v6 为新冻结执行，未将旧结果伪装为新跑。

独立核验当前源码清单、15 个运行期冻结 producer、四个 ELF SHA256、13 个成功 capture 及其 stderr/stdout/memory 文件摘要；全部零源码/producer 漂移且无 fatal。实际两套日志均为 **623 passed、1 skipped、0 failed**，唯一 skip 为 `strategy_host_ipc.test.bounded rings and frozen bridge fail closed`。应用与 CLI 各 30 个真实进程及物理审计通过，adapter fsync 证据通过。256/512 runner 差异仅线程栈和相应注释。

结论仅覆盖 WSL1/lxfs 离线文件功能。sampled RSS 不等于 OS 峰值；allocated bytes 部分可变，实际栈峰值、队列高水位、资源预算、千单压力、性能、目标 Linux 文件系统、断电、NodeFence、凭证/dump 和生产资格仍未取得。未发现需报告的 baseline smell；未以本次结果关闭票 12 或授予平台生产资格。
