# 通过 CredentialStore 完成只读安全准入

Type: task
Status: resolved
Assignee:
Blocked by: [01 冻结首个 Linux 生产合同与 schema](01-freeze-linux-production-contract.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何让 SystemOwner 在 Linux 节点手工解锁最小权限 TradingCredential，并证明 SecretMaterial 只在
授权 ExecutionGateway 的锁定内存中存在且不能绕过 SecurityAdmission？

## What to build

实现人工解锁的加密文件 CredentialStore、ObservationCredential/ExecutionCredential 分离、
Staged → Active → Retiring → Revoked 生命周期以及节点安全自检。先以只读账户查询贯通完整链路，
在本票内不授予下单权限。

## Acceptance criteria

- [x] CredentialStore 使用 Zig 标准库 Argon2id 与 XChaCha20-Poly1305；身份、用途、环境、账户、节点、出口 IP、版本和能力 metadata 作为 AEAD associated data。
- [x] 生产输入入口只接受 TTY 或继承的受限文件描述符；测试口令显式标记为 test-only，不从 argv、环境变量或普通临时文件读取。
- [x] 解锁后的 SecretMaterial 只通过 GatewayLease 进入受保护内存；Linux `mlock`、`MADV_DONTDUMP` 或释放清零失败均阻止准入。
- [x] ObservationCredential 与 ExecutionCredential 使用独立文件和 CredentialKind；生命周期和 metadata 不允许 Demo/Testnet/生产复用。
- [x] 凭证 metadata 固定 `can_withdraw=false`、固定出口 IP；只读 Gateway allowlist 仅含账户读取和对账，订单、资金、账户模式和凭证管理均拒绝。
- [x] 错误口令、认证 metadata 不匹配、权限扩大、账户/节点/IP/环境不匹配、过期和已撤销凭证均失败关闭。
- [x] Staged → Active → Retiring → Revoked 单向持久化；generation 前进，Revoked 优先于旧配置，不能回滚复活。
- [ ] 目标节点上对源码、ReleaseArtifact、日志、指标、进程环境、core dump 和诊断产物的完整 SecretMaterial 扫描：待目标节点与真实凭证资格阶段执行。
- [x] 只读准入只返回 Ready 摘要，`send_capability=false`、`trading_enabled=false`，不调用 EnableTrading。

## Out of scope

- Vault、云密钥服务、TPM 自动解封、无人值守启动和双人审批。
- Demo/Testnet/生产订单写入。

## Answer

已新增 `src/credential_store.zig` 与 `docs/adr/0005-credential-store-read-only-admission-contract.md`。
CredentialStore 使用独立的 `observation.credential`/`execution.credential` 文件，固定 metadata
作为 AEAD associated data；生命周期更新采用临时文件、文件同步、原子替换和目录同步。只有
observation 的只读准入在本票开放，execution admission 明确保持 out-of-scope。

`readPassword` 只接收 TTY 或受限 fd；`ProtectedMemory` 在 Linux 使用 `mlock` 和
`MADV_DONTDUMP`，释放时清零；运行时上下文独立校验 account、environment、node 和固定出口 IP。
当前票据故意保留目标节点 secret-scan、core-dump 与真实 RLIMIT_MEMLOCK 资格为未完成项。

## Evidence

- [x] Windows Debug/ReleaseSafe 全量测试：`195/195`。
- [x] Linux x86_64 ReleaseSafe WSL 原生 ELF `--credential-store-test`：`state=ready`、
  `send_capability=false`、`execution_separate=true`、metadata authenticated、lifecycle persisted。
- [x] Linux x86_64 专用 CredentialStore 测试：加密 metadata、错误口令、保护自检、权限 allowlist、
  生命周期和撤销不可复活路径通过。
- [ ] 目标生产节点密钥扫描、core dump、RLIMIT_MEMLOCK、真实账户和目标发行版资格：待后续票。
