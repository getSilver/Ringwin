# 08: 贯通控制与账户协调历史回收

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 贯通检查点、日志轮转与崩溃恢复](03-close-checkpoint-and-journal-rotation.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何长时间重复操作与共享账户协调可持续运行，回收历史后过期权限和旧控制命令不会重新生效？

## What to build

长时间重复操作与共享账户协调可持续运行，回收历史后过期权限和旧控制命令不会重新生效。

## Acceptance criteria

- [x] 覆盖 Operational 控制命令、策略 fence、安全 gate、账户协调和强制分配的累计证据，明确可回收与必须保留的状态。
- [x] 通过公共控制事实/协调输入，完成多轮暂停、恢复、撤权、风险分配和历史回收再恢复；不同分片共享账户时归属正确。
- [x] 旧命令重复不重复执行，内容冲突拒绝，过期授权/lease 不因恢复或历史缺失重新生效；token/generation 不回退。
- [x] 未闭合风险占用、有效锁存和未完成协调不被清理；归档查证失败保持新增风险关闭。
- [x] 至少跨每种相关累计上限并故障恢复；公共状态与摘要一致，不依赖新 Web UI 或平台进程接线。

## Evidence

2026-10-16完成小规模功能闭合，见[08证据](../08-evidence.md)、[双轴审查](../08-review.md)和[149项最终审计](../08-final-v3-acceptance-audit.json)。107份源码身份为`1ac484f6586253131c2f8845821d54a6d4fc2b2edb63579d0d72dd9a41d02c71`。

公共Owner/Store/Gateway控制与协调输入覆盖320命令、160 gate/latch、80 fence、80真实Core/Cutover切换；四片各自经济应用/持久ack后完成320强制分配source及320顺序共享路由回收。十轮四片lease恢复、完整原始source/全部posting、驻留订单风险引用、冷热same/conflict、expiry、错误Coordinator来源、未完成协调和查询故障均有回归。12000协调摘要、400次checkpoint/recover跨十个旧journal字节窗口。

最终冻结Debug/ReleaseSafe完整串行各602/602退出0，全部10步同源码drift0。应用64MiB与CLI256MiB重建、各两个离线模式退出0；原始日志、四产物哈希、实际PE栈、六类十轮原生输出及资格标志通过149项审计。Standards/Spec无剩余确认P1/P2。复核：`python .scratch/core-continuous-capacity/audit-08-final.py 08-final-v3`。

## Out of scope

本票已按implement请求实施并完成离线功能验收。每类live/terminal跨全部分片各不超过100；千单容量、压力/RSS/索引成本与目标平台性能仍deferred。没有部署、真实Demo/Testnet/生产下单，也不授予平台或Venue生产资格；Windows链总资格仍blocked。
