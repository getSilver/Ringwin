---
status: accepted
date: 2026-09-06
---

# CredentialStore 与只读安全准入合同

票 04 的目标是让 Linux 节点可以人工解锁一个最小权限的观察凭证，同时保持交易授权关闭。
凭证文件和受保护内存属于 `CredentialStore` implementation；TradingShard 不持有凭证或解锁口令。

## Decision

- 使用 Zig 标准库提供的 Argon2id 和 XChaCha20-Poly1305。固定 metadata（身份、用途、环境、账户、
  节点、固定出口 IP、版本、代次、有效期和能力位）作为 AEAD associated data。
- 口令输入只接受 TTY 或调用方继承的受限文件描述符。`readPassword` 不读取 argv、环境变量或
  路径指定的普通临时文件；测试 fixture 只能使用显式 `test_only` source 和 bypass protection。
- 解锁后的 `SecretMaterial` 只通过 `GatewayLease` 进入按页对齐的受保护内存；Linux 必须成功
  `mlock` 和 `MADV_DONTDUMP`，释放时清零。任一能力、自检、账户、节点、出口 IP、环境或有效期
  检查失败，准入保持关闭。
- `observation.credential` 与 `execution.credential` 是两个独立的加密文件和 `CredentialKind`。
  本票只实现 observation 的 read-only admission；execution admission 明确返回 out-of-scope，
  因而没有 EnableTrading 或发送能力。
- 生命周期只能按 `Staged -> Active -> Retiring -> Revoked` 前进；每次切换提升 generation，
  文件通过临时文件、文件同步、原子替换和目录同步持久化。Revoked 在解锁判断中优先于旧配置，
  不能由旧 metadata 复活。
- Gateway allowlist 当前只允许账户读取和账户对账；资金转移、账户模式变化、凭证管理和订单写入
  都不属于只读准入。

## Consequences

`--credential-store-test` 是明确的 Linux acceptance entry，输出只包含状态和能力摘要，不包含
credential bytes。WSL 原生 ELF 只证明当前 Linux ABI 的链路回归；目标发行版、节点权限、RLIMIT_MEMLOCK、
真实凭证、进程转储和生产密钥扫描仍需在目标节点资格票中执行。
