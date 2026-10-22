# 实现 Windows CredentialStore 验证适配器

Type: task
Status: resolved
Assignee: grok
Blocked by: [03 实现 Windows DurableStore 验证适配器](03-add-windows-durable-store-adapter.md)
Parent: [Windows 进程链验证](../map.md)

## Question

如何在 Windows 上解锁 ObservationCredential 进入受保护内存，并证明这不能替代 Linux
mlock/DONTDUMP 生产准入，也不能打开 execution admission？

## What to build

为 CredentialStore 增加 Windows 验证路径：Argon2id / XChaCha20-Poly1305 与现有 metadata AEAD
不变；口令只来自控制台或继承的受限 handle，读取前关闭回显并在所有退出路径恢复；SecretMaterial
使用 `VirtualLock`（或等价锁页）与释放清零。Observation 与 Execution 分文件、单向生命周期保持。

本票只达到 read-only Ready：`send_capability=false`、`trading_enabled=false`。execution
admission 继续 out-of-scope。明确记录 Windows 保护不等价于 Linux `mlock` + `MADV_DONTDUMP`。

## Acceptance criteria

- [x] 生产输入不从 argv、环境变量或普通临时文件读口令；控制台路径关闭并恢复回显。
- [x] 解锁后的 SecretMaterial 只经 GatewayLease 进入锁页内存；锁页或清零失败则拒绝准入。
- [x] Observation/Execution 分文件；错误口令、metadata 不匹配、过期、撤销失败关闭。
- [x] Ready 摘要 `send_capability=false`、`trading_enabled=false`，不调用 EnableTrading。
- [x] `zig build` 提供 Windows 验收 step，输出标明 `protection=windows_virtual_lock` 且
      `linux_admission_equivalent=false`。
- [x] 生产票 04 不因本 adapter 关闭。

## Out of scope

- Linux 目标节点 secret-scan、RLIMIT_MEMLOCK、core dump、真实生产账户。
- 把凭证注入五 role 发送路径（票 05）。
- Demo/Testnet/生产交易所密钥活链。

## Answer

- Windows 口令只接受 TTY（关回显）或 `GetFileType==FILE_TYPE_PIPE` 的受限 handle。
- Native 保护为 `VirtualLock`；`dont_dump` 不为 true，`linux_admission_equivalent=false`。
- `zig build windows-credential` 输出 `protection=windows_virtual_lock`、
  `send_capability=false`、`trading_enabled=false`。
- 生产票 04 仍为 ready-for-agent。
