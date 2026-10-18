# 04 清理认证与传输副本

Type: task
Status: blocked
Assignee:
Blocked by: [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让auth和TransportOwner真正管理受保护凭证，并清理每次签名及C请求副本？

## Acceptance criteria

- [ ] HMAC上下文、可管理pad/scratch/digest/signature在全部退出路径明确擦除，已知签名向量不变。
- [ ] Credentials长期存储使用02保护内存/明确所有权，避免按值secret复制和构造失败残留；调用点同步更新。
- [ ] Headers/LoginPayload及C shim认证头副本，在成功和故障退出均安全擦除后释放，纯合成公开transport测试验证。
- [ ] 暴露给05的凭证接入接口稳定；编译器/TLS/OS临时内存不作已证清零声明。
- [ ] 定向Debug/ReleaseSafe/ReleaseFast及无网络C验证通过，记录证据提交。

## Evidence

待实施。可修改auth/transport/C shim及构造调用签名；原始输入来源的网关/脚本改造属于05。
