# 06 最终冻结、回归与独立审查

Type: task
Status: blocked
Assignee:
Blocked by: [05 网关注入](05-bind-gateway-credential-ownership.md), [07 AEAD 工作区](07-protect-aead-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何以同一最终源码证明本轮修复，且不把离线通过提升为目标机生产资格？

## Acceptance criteria

- [ ] 01–05、07与08全部resolved，原问题逐项映射修复/回归入口；失败与剩余未测完整列明。
- [ ] 最终冻结后完整Debug/ReleaseSafe及受影响应用/独立入口构建通过；Linux按实际环境分列验证/skip，不虚报。
- [ ] 记录最终源码/工具链/构建参数/命令/产物和原始日志身份；不复用旧源码资格。
- [ ] 独立Standards/Spec审查，无剩余确认P1/P2；修复review问题后执行所需检查。
- [ ] 集成分支提交完成、本地tracker闭合，实现者临时工作树清理；不自动合main或推送/部署。

## Evidence

待实施。真实凭证、网络、生产授权、目标dump/swap/掉电、TLS/OS内部缓冲资格均不在本轮宣称范围。
