# 11: 验证 Linux 文件持久化与持续恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [09 贯通千单负载与安全背压](09-qualify-live-order-capacity-and-backpressure.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何Linux 文件适配器承载同一核心负载，在多轮归档和进程重启后恢复正确状态，形成独立的平台容量证据？

## What to build

Linux 文件适配器承载同一核心负载，在多轮归档和进程重启后恢复正确状态，形成独立的平台容量证据。

## Acceptance criteria

- [ ] 在 Linux 文件适配器运行票 09 公共业务链，贯通输入、发送前屏障、归档、快照、文件重开和新进程恢复；交叉编译不能替代运行结果。
- [ ] 注入写入/同步/发布/回收失败及进程中断；恢复旧或新完整状态，缺段/摘要错误失败关闭，Unknown 不重发。
- [ ] 记录 OS/文件系统、源码树、artifact、schema、种子、内存峰值、队列水位、日志增长与恢复耗时，并保留所有失败/未执行结果。
- [ ] 满足票 01 的 Linux 容量与文件恢复预算；成功结果可独立交给 Linux 生产专项，不等待 Windows 票。
- [ ] 不自动运行破坏性目标机断电、线上交易或凭证操作；WSL/开发 Linux 结果不替代目标节点持久化、性能或完整 Linux 生产资格。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
