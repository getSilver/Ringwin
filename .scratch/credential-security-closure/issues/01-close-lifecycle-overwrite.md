# 01 封闭凭证生命周期覆盖与并发回退

Type: task
Status: ready-for-agent
Assignee:
Blocked by:
Parent: [凭证安全修复](../map.md)

## Question

如何让stage与状态切换保留撤销事实，不被原身份重建或并发旧写覆盖？

## Acceptance criteria

- [ ] 公共API复现撤销后原身份stage并再激活的红测试，修复后拒绝并保留文件字节/代次。
- [ ] stage不覆盖任意已有kind文件，包括损坏/不同密码；首次创建并发只有一个成功。
- [ ] 状态切换校验持久当前metadata/generation，并防止并发旧状态覆盖revoked。
- [ ] 临时文件唯一/受限权限，失败关闭并关闭句柄/清理自身临时文件；不伪装目录sync降级为目标耐久性证明。
- [ ] 公共生命周期/错误口令/原文件兼容定向回归通过，证据写本票并提交。

## Evidence

待实施。范围为credential_store生命周期及相关公共测试，不修改保护内存/密码学新模块。
