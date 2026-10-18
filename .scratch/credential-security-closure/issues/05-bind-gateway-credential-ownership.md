# 05 贯通网关受控凭证注入

Type: task
Status: blocked
Assignee:
Blocked by: [03 安全store与输入](03-integrate-protected-store-and-input.md), [04 认证与传输](04-protect-auth-and-transport-copies.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让实际网关/独立Demo入口不再依赖秘密环境变量，并保持平台、账户和用途授权分离？

## Acceptance criteria

- [ ] 网关及独立OKX入口使用受控pipe/store注入和04保护owner，禁用/删除秘密环境变量回退。
- [ ] 启动工具同步改造，秘密不进argv/env/日志或普通临时文件；进程角色只取得自己的凭证。
- [ ] 合成子进程/transport公共seam验证输入失败、正常使用、重启/释放及无secret日志/环境泄漏。
- [ ] observation/execution与demo/testnet/production分离；生产admitExecution仍拒绝，不通过更名verification授生产资格。
- [ ] 所有受影响runner编译、离线链通过，未发真实网络/订单，记录并提交。

## Evidence

待实施；如受控pipe直接导入Demo材料，必须写清只属显式Demo用途，不能冒称production CredentialStore接入。
