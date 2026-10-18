# 07 保护 AEAD 子密钥与显式工作区

Type: task
Status: resolved
Assignee: Codex AEAD implementer
Blocked by: [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何保护 XChaCha20-Poly1305 内部显式子密钥、状态和 keystream，保持现有容器兼容？

## Acceptance criteria

- [x] 固定标准库来源与许可证的窄适配，不自创密码学算法；保留20 rounds、nonce/counter、容器格式。
- [x] key 以指针借用；子密钥、ChaCha ctx/x、keystream、polyKey 与 Poly1305 context 在写入前进入受保护 Scratch；避免显式敏感数组按值返回。
- [x] 成功、认证失败、保护失败均擦除自有工作区，认证失败明确清空调用方输出；不把编译器寄存器/临时值清零作为已证事实。
- [x] 已确认公共 crypto/memory seam 的红绿测试、标准向量、原 stdlib 对照边界长度及失败清理通过；Windows/Linux 定向验证。
- [x] 与03协调：本票仅新增 credential_aead/窄依赖和测试，03拥有 store 文件；合入后03或本票后续单独改调用点，最终冻结前必须使用新实现并通过旧文件兼容。

## Evidence

只读核查：`D:/github/Ringwin-credential-recovery-20261018/aead-state-notes.md`。Poly1305.final 已有清零，遗漏在其他显式副本与活跃期；不是已复现的 ReleaseSafe 释放后利用。原02 KDF验收保持有效，此票补齐 AEAD。

稳定API已与03确认：`credential_aead.encrypt(c, *[16]tag, m, ad, [24]nonce, *const[32]key)!void`；`decrypt(m,c,[16]tag,ad,[24]nonce,*const[32]key)!void`。其余参数同原stdlib，key只借用指针；每次先保护Scratch再处理secret，无io。错误明确清空decrypt输出，encrypt错误清c/tag；调用方仍拥有并清理输入key/plaintext。`key_length=32,nonce_length=24,tag_length=16`保留。03拥有store接入，本票不并行修改store。

首个public加密字节兼容回归先红NotImplemented后绿ReleaseSafe1/1；原始[红](../07-red-compat.log)、[绿](../07-green-compat.log)。完整模块向量、边界与native/失败观测随后完成如下。

模块checkpoint（未关闭集成AC）：[07-evidence.md](../07-evidence.md)、[07-validation.json](../07-validation.json)。Windows ReleaseSafe/Fast与WSL Linux ReleaseFast各10/10；54对消息/AAD边界、原stdlib双向字节互通、已知XChaCha/RFC Poly1305、五类tamper、四种保护失败与清理、真实保护owner均通过。单独非test生产模块在Linux子进程memlock0下观察MemoryLockFailed且输出清零，退出0。原始运行日志实际存在且已hash记录，不使用仅编译结果冒充运行通过。

最终已在03完成并合入`32ab7200`后顺序接入，未与03并行修改store。四处最小diff使用其外部patch（CRLF规范LF后apply），新证据[07-integration-validation.json](../07-integration-validation.json)绑定实际捕获source `b1df784e6655962b952dd071929a7ab0b18f7859b9c19e4296afa91f467bcf51`。Windows/Linux ReleaseSafe store各38/38，原CRD4 v1读取/撤销及生命周期公共seam通过；默认Linux限额拒绝1/1；两OS non-test小entry实际ready/read_only/send=false。全部9个捕获阶段exit0、无源漂移/崩溃/超时，未改03旧身份清单。最后合入04最新`86de526d`后，[依赖闭包比对](../07-postmerge-validation.json)确认store全部11个import/embed文件与已验字节相同；变化只在7个独立auth/provenance文件。新全局source `733fff39b915805135ccb01d1fc97f27e0f5b727324f57afa2add1ad6e9654e5`的最终全量冻结、目标dump/swap/生产资格仍由集成验收另证，无网络或真实凭证。
