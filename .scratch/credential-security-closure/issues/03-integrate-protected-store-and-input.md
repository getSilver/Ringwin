# 03 贯通凭证存储的保护内存与安全输入

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 生命周期](01-close-lifecycle-overwrite.md), [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让store解锁/编码/解码/口令真正使用安全工作区，并消除TTY和输入截断缺口？

## Acceptance criteria

- [x] 公共stage/transition/admission不再把模块管理的plaintext/KEK/material长期放普通栈或按值复制，复用02。
- [x] 口令受限fd实际校验；Linux关闭回显或读取前明确拒绝TTY，错误/过长输入不静默截断且擦除。
- [x] 权限/认证/运行上下文失败仍关闭准入，stage调用方原material和password成功失败均清零。
- [x] decode长度/格式异常返回错误，不越界panic；新旧加密文件兼容，无schema静默降级。
- [x] Windows实际入口/管道和Linux可用功能定向验证，记录native/skip边界并提交。

## Evidence

2026-10-18：受保护输入、password/payload/KEK/decode lease、长度拒绝、Linux TTY读取前拒绝、0700及独占随机fixture已实现。Windows/WSL bounded ReleaseSafe各32/32，默认64KiB public stage拒绝1/1，双方native acceptance函数退出0；CRD4/v1兼容保持。详见[03证据](../03-evidence.md)和[身份清单](../03-validation.json)。AEAD库内部显式状态仍由07修复，本票未声称已保护；最终应用dispatch/全量由06冻结后验证，不扩大生产execution授权。
