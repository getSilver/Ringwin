# 通过 CredentialStore 完成只读安全准入

Type: task
Status: ready-for-agent
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
- [ ] 生产优先使用受限 pipe/socket fd 输入口令；如保留交互 TTY，读取前关闭 ECHO/ECHONL，并在成功、失败、信号和异常路径恢复 termios 后输出换行。
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

2026-09-09 源码复审补充：TTY 路径当前只验证输入来自终端，尚未关闭终端回显，因此交互解锁安全
仍为未完成；受限 fd 路径不受该显示问题影响。

2026-09-07 修复复核：删除 `PasswordSource.tty/restricted/testOnly` 的公开构造器，生产调用方只能
通过实际 `readPassword` 路径取得来源标记；密钥内存加固沿用提交 `549282f`。

## Evidence

- [x] Windows Debug/ReleaseSafe 全量测试：`195/195`。
- [x] Linux x86_64 ReleaseSafe WSL 原生 ELF `--credential-store-test`：`state=ready`、
  `send_capability=false`、`execution_separate=true`、metadata authenticated、lifecycle persisted。
- [x] Linux x86_64 专用 CredentialStore 测试：加密 metadata、错误口令、保护自检、权限 allowlist、
  生命周期和撤销不可复活路径通过。
- [ ] 目标生产节点密钥扫描、core dump、RLIMIT_MEMLOCK、真实账户和目标发行版资格：待后续票。

### 目标机执行（2026-09-21）

- `RLIMIT_MEMLOCK=8MiB`、`RLIMIT_CORE=0` 下只读 CredentialStore acceptance 通过，结果保持
  `state=ready`、`send_capability=false`；运行探针确认 `VmLck=4kB` 且 secret mapping 同时带
  locked 与 `MADV_DONTDUMP` 标志。
- 运行时编码 marker 的 core 探针证明未保护控制 marker 可在 core 中检出，而受保护 marker 不在
  core 中；首个把 marker 字面量编入 ELF 的无效探针作为失败证据保留。
- 以真实 Demo 凭证值对 release、unit、日志和诊断证据进行内容扫描为 0 命中，argv 不含凭证。
  当前 Demo runner 仍通过进程环境承载凭证，生产 ObservationCredential、完整 metrics/env 扫描及
  Linux TTY termios 验收未闭合，因此不勾选完整准入项、不关闭本票。
