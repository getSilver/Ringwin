# 02: 分离权威屏障与内存 Trace 下标

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [01 冻结业务负载、容量和保留合同](01-freeze-capacity-and-retention-contract.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何在不改变订单与经济行为的前提下，让权限、游标和恢复依赖连续的权威屏障，为后续 Trace 轮转建立可验证基线？

## What to build

在不改变订单与经济行为的前提下，让权限、游标和恢复依赖连续的权威屏障，为后续 Trace 轮转建立可验证基线。

## Acceptance criteria

- [ ] 从公共 CanonicalEvent 输入到权限引用、策略游标、快照和重放使用一致的全局单调屏障；内存窗口位置不再充当永久身份。
- [ ] 复核全部依赖 Trace 长度的消费者以及溢出行为；新旧表示存在期间有明确等价校验，不允许混用产生有效权限。
- [ ] 这是前置广域重构：若不能一次保持回归通过，采用先扩展、分批迁移、最后删除旧表示；仅在同一票约束内保留临时表示，不建立长期双 schema 兼容。
- [ ] 按票 01 决议更新摘要及 schema 合同；未知或旧 schema 失败关闭，不复用历史资格。
- [ ] 同一业务轨迹在变更前后业务结果一致；当前 schema 下 live/snapshot/tail-replay 摘要一致，恢复路径无发送能力。通过现有公共接口回归后才启用轮转。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

用户已授权本票本地实现；不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
