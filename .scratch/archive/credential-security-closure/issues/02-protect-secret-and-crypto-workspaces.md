# 02 建立受保护缓冲与可清零密码学工作区

Type: task
Status: resolved
Assignee: Codex protected-memory implementer
Blocked by:
Parent: [凭证安全修复](../map.md)

## Question

如何使敏感工作区在写入前保护、退出前明确擦除，且不依赖优化模式或分配器填充？

## Acceptance criteria

- [x] 公共保护内存接口，按页分配、先保护后写、访问转换与失败关闭；真实Windows/Linux路径与仅测试backend分清。
- [x] 公共分配/释放seam红绿测试证明正常、锁定失败、保护失败和取消/异常清理，释放前真正secureZero。
- [x] KDF与原Argon2id参数/文件兼容，工作区和可管理crypto状态显式擦除；ReleaseSafe/ReleaseFast均不依赖undefined poison。
- [x] 保留固定密码学来源/许可证，已知向量与受保护工作区释放观测通过，不自创算法。
- [x] 将稳定的保护内存/KDF接口及验证记录写票，供03/04复用；不修改credential_store或auth/transport现有文件。

## Evidence

实施接口（2026-10-18，供03/04复用）：

- `protected_memory.Buffer.init(len)`：native按页拥有，完成锁页（Linux另DONTDUMP）后才交付；`writable()`取得写切片，`freeze()`转换只读，`bytes()`取得只读切片，`deinit()`恢复写、secureZero完整页、解锁释放。不可复制有主权的Buffer；使用后切片不得逃逸生命周期。
- `Buffer.initForTesting(len, backend)`：仅`builtin.is_test`可用的可观测backend；不是生产配置降级。`report()`报告locked/dont_dump/read_only；Windows不宣称DONTDUMP资格。
- `credential_kdf.derive(io, password, salt, *[32]u8)`：固定兼容`Params.owasp_2id`（t=2,m=19456KiB,p=1），直接写调用方目标，**调用方须把password和输出目标预先放进受保护Buffer**；工作区自己分配保护，容量为19MiB blocks加`sizeof(Scratch)+alignof(Scratch)`，锁页失败直接错误，不降级。仅测试另有backend入口。
- 活跃期间H0、hash context、Blake2b压缩m/v、long-hash数组、序列化block、segment地址/input以及Argon2压缩t/buffer均由同一受保护allocator分配Scratch拥有；initHash写入指针不按值返回H0。退出显式secureZero。p4验证按slice内lane串行复用Scratch，引用索引和同步点不变，生产原本p1。编译器寄存器/临时副本、TLS/OS内部和目标dump/swap资格不由这些测试证明。

Windows owner须显式调用一次`protected_memory.configureNativeLockBudget(bytes)`；参数范围1..64MiB，仅提高本进程working-set预算且串行不降低，不在Buffer.init中静默调用，不保证绕过VirtualLock。当前单KDF测试用24MiB预算；并发KDF需显式预算或串行。

Linux调用前由supervisor设置足够soft memlock；模块检查当前soft限额并跟踪自有rounded页总量，之后仍实际mlock。WSL1可在64KiB限额下错误地返回20MiB mlock成功，因此此显式限额不能省；默认限制测试明确拒绝、输出全零，无skip。64MiB子进程限额在降uid1000后通过真实native功能测试。

最终验收：[02-evidence.md](../02-evidence.md)、[02-v2-validation.json](../02-v2-validation.json)。Windows ReleaseSafe/ReleaseFast各9/9，Linux ReleaseFast默认限额拒绝与child-local64MiB native成功各9/9；全部合成凭证、无网络、无真实凭证。新增allocator seam先红后绿，证明额外crypto scratch从保护区域分配且后续OOM时释放。完整页在unlock/free前由observer观测为0。固定MIT窄fork、RFC9106与旧OWASP兼容向量通过；不改credential_store/auth/transport。首轮55e06e2f的8/8和[原身份记录](../02-validation.json)保留为历史阶段证据，不能覆盖后续发现的普通栈scratch活跃窗口；v2已修复此窗口。最终集成冻结验收由后续票完成，目标dump/swap及编译器/TLS/OS内部残留仍未资格化。
