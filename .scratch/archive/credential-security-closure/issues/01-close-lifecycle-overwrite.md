# 01 封闭凭证生命周期覆盖与并发回退

Type: task
Status: resolved
Assignee: Codex lifecycle implementer
Blocked by:
Parent: [凭证安全修复](../map.md)

## Question

如何让stage与状态切换保留撤销事实，不被原身份重建或并发旧写覆盖？

## Acceptance criteria

- [x] 公共API复现撤销后原身份stage并再激活的红测试，修复后拒绝并保留文件字节/代次。
- [x] stage不覆盖任意已有kind文件，包括损坏/不同密码；首次创建并发只有一个成功。
- [x] 状态切换校验持久当前metadata/generation，并防止并发旧状态覆盖revoked。
- [x] 临时文件唯一/受限权限，失败关闭并关闭句柄/清理自身临时文件；不伪装目录sync降级为目标耐久性证明。
- [x] 公共生命周期/错误口令/原文件兼容定向回归通过，证据写本票并提交。

## Evidence

2026-10-18，仅修改 `src/credential_store.zig` 的持久生命周期、文件发布和公共生命周期回归；未改变 CRD4/v1、Argon2/AEAD 参数或生产 `admitExecution`。

- 首个真实 pipe → 公共 stage/activate/revoke 红测试复现撤销后重写；修复后 `CredentialAlreadyRegistered`，原文件字节不变且旧 active metadata 仍被 `CredentialRevoked` 拒绝。基线另复现损坏文件覆盖、不同口令/版本覆盖、首次双 writer 都成功、独立 writer 锁被忽略。红日志保留于本目录 `01-red-*.log`。
- 所有 writer 先锁持久独立 `credential.writer.lock`，持锁完成认证 metadata/generation 核对与发布；不会锁被 rename 替换的 credential inode。竞争失败为 `CredentialWriterBusy`。不删除锁文件；generation 溢出明确拒绝。
- 随机 128-bit 临时文件名、exclusive 创建、Linux 0600，所有写入/同步/发布错误均 defer 关闭句柄并清理自有临时路径。首次 Linux `linkat` / Windows rename-preserve 原子拒绝任意已有路径；状态切换才允许 rename-replace。损坏文件拒绝回归同时核对无临时泄漏且旧固定 `.tmp` 哨兵不被改动。
- Linux目录使用实际可 fsync 的 iterate fd，移除 BADF/INVAL→全局 sync 的伪降级。Windows仍仅记录既有文件FlushFileBuffers功能链，不声称目录/ACL/断电资格。
- Windows Debug/ReleaseSafe、WSL1 Linux Debug/ReleaseSafe 定向模块含依赖各17/17（8个凭证测试，其中5个新增公共回归），随后同一实现新增原审计CRD4/v1合成文件兼容测试，两平台两模式各1/1；不同测试源码身份已在清单分列，新增仅测试和合成fixture；日志和编译器/源码/产物 SHA 见 `../01-validation.json`。Linux Debug 原始 strace 同时记录成功 flock、linkat、文件与目录 fsync。
- 初始 std File.Atomic 方案在 WSL1 `renameat2(RENAME_NOREPLACE)` 返回 ENOSYS，随后 panic 追栈 statx ENOSYS 挂起；已终止自有进程，失败日志保留，并由等价的首次 exclusive hard-link 发布修复。误把 `--test-filter` 传给测试产物的诊断原件也保留，不计作通过。
- `zig fmt --check src/credential_store.zig`、`git diff --check` 通过。未执行全量、真实凭证、网络/交易；最终冻结后的全量与独立审查由票06统一执行。Linux目录所有者/权限、Windows ACL、目标机dump/掉电、任意文件系统整体回滚外部锚仍是各自资格/后续入口收口边界。
