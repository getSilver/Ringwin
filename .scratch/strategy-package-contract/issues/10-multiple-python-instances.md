# 10：多个 Python 实例共存与共享 Host 生命周期

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [05 Python 实例 checkpoint 与重启恢复](05-python-checkpoint-recovery.md)、[06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)、[08 代码替换与 ForwardRollback 创建 StrategySuccessor](08-successor-rollback.md)
Parent: [模块地图](../map.md)

## Question

如何运行多个Python实例并准确处理目标替换、共享Host故障和恢复的影响范围？

## What to build

验收同定义不同配置和多个定义共存，落实加载组织、内存计量及共享Host生命周期，向Web呈现实际影响范围。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] 同定义不同配置及多个定义可按批准放置运行；模块解析符合各包清单，实例私有状态、输出身份和checkpoint不串用。
- [ ] 明确内存计量口径、包上限到进程预算的映射和Host放置，实际执行所声明限制，不要求进程内逐实例硬隔离。
- [ ] 策略/checkpoint聚合摘要按规范生成并绑定实际集合，不截断完整包摘要或使用占位值。
- [ ] 目标替换仅改变指定实例代码/配置；需要重启共享Host时展示全部受影响实例，并按既有会话失效路径撤权和恢复。
- [ ] 一个Host异常、超时或超内存不阻塞核心及其他Host；验证受影响实例恢复后的身份、序号与权限，没有自动复权。

## Answer / 实现证据

待实施。

