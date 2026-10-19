# 06 最终冻结、回归与独立审查

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 网关注入](05-bind-gateway-credential-ownership.md), [07 AEAD 工作区](07-protect-aead-workspaces.md)
Parent: [凭证安全修复](../map.md)

## Question

如何以同一最终源码证明本轮修复，且不把离线通过提升为目标机生产资格？

## Acceptance criteria

- [x] 01–05、07与08全部resolved，原问题逐项映射修复/回归入口；失败与剩余未测完整列明。
- [x] 最终冻结后完整Debug/ReleaseSafe及受影响应用/独立入口构建通过；Linux按实际环境分列验证/skip，不虚报。
- [x] 记录最终源码/工具链/构建参数/命令/产物和原始日志身份；不复用旧源码资格。
- [x] 独立Standards/Spec审查，无剩余确认P1/P2；修复review问题后执行所需检查。
- [x] 集成分支提交完成、本地tracker闭合，实现者临时工作树清理；不自动合main或推送/部署。

## Evidence

最终[证据](../06-final-evidence.md)与[身份清单](../credential-final-v3-validation.json)：同源35/35阶段exit0，完整Debug/ReleaseSafe各650/650；Windows四入口构建及实际离线链、WSL各模块与凭证入口通过。两轴共享P2由唯一fixer修复后均独立确认关闭，无剩余确认P1/P2。

八工作树已保全33837文件、4453649090字节，清理前再核对原件/副本及提交祖先。清理前八份原件/副本全部哈希一致，八个实现工作树已移除、分支提交保留；[清理状态](../06-cleanup-state.json)为complete。集成分支已完成代码提交并封存最终验收，随本次tracker闭合提交；main不合入。真实凭证、网络、生产授权、目标dump/swap/掉电、TLS/OS内部缓冲资格均不在本轮宣称范围。
