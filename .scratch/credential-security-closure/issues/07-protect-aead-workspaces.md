# 07 保护 AEAD 子密钥与显式工作区

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何保护 XChaCha20-Poly1305 内部显式子密钥、状态和 keystream，保持现有容器兼容？

## Acceptance criteria

- [ ] 固定标准库来源与许可证的窄适配，不自创密码学算法；保留20 rounds、nonce/counter、容器格式。
- [ ] key 以指针借用；子密钥、ChaCha ctx/x、keystream、polyKey 与 Poly1305 context 在写入前进入受保护 Scratch；避免显式敏感数组按值返回。
- [ ] 成功、认证失败、保护失败均擦除自有工作区，认证失败明确清空调用方输出；不把编译器寄存器/临时值清零作为已证事实。
- [ ] 已确认公共 crypto/memory seam 的红绿测试、标准向量、原 stdlib 对照边界长度及失败清理通过；Windows/Linux 定向验证。
- [ ] 与03协调：本票仅新增 credential_aead/窄依赖和测试，03拥有 store 文件；合入后03或本票后续单独改调用点，最终冻结前必须使用新实现并通过旧文件兼容。

## Evidence

只读核查：`D:/github/Ringwin-credential-recovery-20261018/aead-state-notes.md`。Poly1305.final 已有清零，遗漏在其他显式副本与活跃期；不是已复现的 ReleaseSafe 释放后利用。原02 KDF验收保持有效，此票补齐 AEAD。
