# 03 贯通凭证存储的保护内存与安全输入

Type: task
Status: blocked
Assignee:
Blocked by: [01 生命周期](01-close-lifecycle-overwrite.md), [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让store解锁/编码/解码/口令真正使用安全工作区，并消除TTY和输入截断缺口？

## Acceptance criteria

- [ ] 公共stage/transition/admission不再把模块管理的plaintext/KEK/material长期放普通栈或按值复制，复用02。
- [ ] 口令受限fd实际校验；Linux关闭回显或读取前明确拒绝TTY，错误/过长输入不静默截断且擦除。
- [ ] 权限/认证/运行上下文失败仍关闭准入，stage调用方原material和password成功失败均清零。
- [ ] decode长度/格式异常返回错误，不越界panic；新旧加密文件兼容，无schema静默降级。
- [ ] Windows实际入口/管道和Linux可用功能定向验证，记录native/skip边界并提交。

## Evidence

待实施；不扩大生产execution授权。
