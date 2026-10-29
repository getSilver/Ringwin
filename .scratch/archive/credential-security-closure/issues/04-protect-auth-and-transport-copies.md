# 04 清理认证与传输副本

Type: task
Status: resolved
Assignee: Codex auth recovery implementer
Blocked by: [02 保护内存](02-protect-secret-and-crypto-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何让auth和TransportOwner真正管理受保护凭证，并清理每次签名及C请求副本？

## Acceptance criteria

- [x] HMAC上下文、可管理pad/scratch/digest/signature在全部退出路径明确擦除，已知签名向量不变。
- [x] Credentials长期存储使用02保护内存/明确所有权，避免按值secret复制和构造失败残留；调用点同步更新。
- [x] Headers/LoginPayload及C shim认证头副本，在成功和故障退出均安全擦除后释放，纯合成公开transport测试验证。
- [x] 暴露给05的凭证接入接口稳定；编译器/TLS/OS临时内存不作已证清零声明。
- [x] 定向Debug/ReleaseSafe/ReleaseFast及无网络C验证通过，记录证据提交。

## Evidence

2026-10-18，原实现f426b3c8与中断后的修改完整保留。受保护Credentials/HMAC/Headers/LoginPayload、借用TransportOwner/C header链表、头注入拒绝及错误清理已实现。Windows auth Debug/ReleaseSafe/ReleaseFast和Linux ReleaseSafe各10/10，合成transport1/1，C请求成功及init/每个setopt/send/recv/cleanup错误矩阵通过。11个补证阶段退出0且无源码漂移；详见[修复与边界](../04-evidence.md)、[身份汇总](../04-validation.json)。已合入集成32ab7200，未改变通过的auth/C生产源码。

05接入接口：Credentials.initEmpty → writableFields → sealLengths（受保护目的地）；或兼容init借用输入，调用方擦除原缓冲。TransportOwner.init/initWithEndpoint使用*const Credentials借用，其所有者须存活至transport deinit之后。Headers/LoginPayload消费后clear；公开sign输出由调用方提供受保护目的地并管理清零。

根runtime/demo/private_smoke旧by-value/env调用点留05，不声称本票根应用可编译；未打开生产准入。编译器/TLS/OS内部残留及目标平台dump/swap仍未资格化。历史C假绿04-c-red.log明示无效，实际行为红04-c-red-checked.log及其他失败原件完整保留。
