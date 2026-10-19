# 05 贯通网关受控凭证注入

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 安全store与输入](03-integrate-protected-store-and-input.md), [04 认证与传输](04-protect-auth-and-transport-copies.md), [08 原生前后验](08-preserve-native-demo-account-guards.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让实际网关/独立Demo入口不再依赖秘密环境变量，并保持平台、账户和用途授权分离？

## Acceptance criteria

- [x] 网关及独立OKX入口使用受控pipe/store注入和04保护owner，禁用/删除秘密环境变量回退。
- [x] 启动工具同步改造，秘密不进argv/env/日志或普通临时文件；进程角色只取得自己的凭证。
- [x] 合成子进程/transport公共seam验证输入失败、正常使用、重启/释放及无secret日志/环境泄漏。
- [x] observation/execution与demo/testnet/production分离；生产admitExecution仍拒绝，不通过更名verification授生产资格。
- [x] 所有受影响runner编译、离线链通过，未发真实网络/订单，记录并提交。
- [x] 迁移managed preflight时，完整保留既有首次写前与正常/失败后的账户安全门；复用08原生guard，不能直接删后验或将caller UID当真实资格。

## Evidence

实现与定向验证已封存，见 [05-evidence.md](../05-evidence.md)、[05-validation.json](../05-validation.json) 和 [最终状态](../05-final-v2-state.json)。Demo pipe 不属于 production CredentialStore signing lease。已知 verify-okx-demo-wave 的 LASTEXITCODE 问题留给 06 独立审查修复；四 wrapper 成功不覆盖其长 verify 前缀。独立审查、最终全量验收和线上资格仍未完成，本票 resolved 不代表整个加密任务完成。
