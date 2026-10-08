# 08: 贯通控制与账户协调历史回收

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何长时间重复操作与共享账户协调可持续运行，回收历史后过期权限和旧控制命令不会重新生效？

## What to build

长时间重复操作与共享账户协调可持续运行，回收历史后过期权限和旧控制命令不会重新生效。

## Acceptance criteria

- [ ] 覆盖 Operational 控制命令、策略 fence、安全 gate、账户协调和强制分配的累计证据，明确可回收与必须保留的状态。
- [ ] 通过公共控制事实/协调输入，完成多轮暂停、恢复、撤权、风险分配和历史回收再恢复；不同分片共享账户时归属正确。
- [ ] 旧命令重复不重复执行，内容冲突拒绝，过期授权/lease 不因恢复或历史缺失重新生效；token/generation 不回退。
- [ ] 未闭合风险占用、有效锁存和未完成协调不被清理；归档查证失败保持新增风险关闭。
- [ ] 至少跨每种相关累计上限并故障恢复；公共状态与摘要一致，不依赖新 Web UI 或平台进程接线。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
