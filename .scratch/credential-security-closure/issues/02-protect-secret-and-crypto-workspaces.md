# 02 建立受保护缓冲与可清零密码学工作区

Type: task
Status: ready-for-agent
Assignee:
Blocked by:
Parent: [凭证安全修复](../map.md)

## Question

如何使敏感工作区在写入前保护、退出前明确擦除，且不依赖优化模式或分配器填充？

## Acceptance criteria

- [ ] 公共保护内存接口，按页分配、先保护后写、访问转换与失败关闭；真实Windows/Linux路径与仅测试backend分清。
- [ ] 公共分配/释放seam红绿测试证明正常、锁定失败、保护失败和取消/异常清理，释放前真正secureZero。
- [ ] KDF与原Argon2id参数/文件兼容，工作区和可管理crypto状态显式擦除；ReleaseSafe/ReleaseFast均不依赖undefined poison。
- [ ] 保留固定密码学来源/许可证，已知向量与受保护工作区释放观测通过，不自创算法。
- [ ] 将稳定的保护内存/KDF接口及验证记录写票，供03/04复用；不修改credential_store或auth/transport现有文件。

## Evidence

待实施。先独立新增模块，接口随实现记录；实际OS权限/目标dump资格仍另验。
