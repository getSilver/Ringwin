# 11: 验证 Linux 文件持久化与持续恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: [09 贯通千单负载与安全背压](09-qualify-live-order-capacity-and-backpressure.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何Linux文件适配器承载同一小规模核心业务，在多轮归档和进程重启后恢复正确状态，形成独立的文件功能证据？

## What to build

Linux文件适配器承载同一小规模核心业务，在多轮归档和进程重启后恢复正确状态；原平台容量与资源目标保留为未测设计参考。

## Acceptance criteria

- [x] 在Linux真实FileAdapter运行票09的同一小规模公共业务链，每个夹具跨全部分片live和terminal总量分别不超过100；贯通输入、发送前屏障、归档、快照、文件重开及新进程恢复，交叉编译不能替代运行结果，禁止千单容量／压力测试。
- [x] 注入写入／同步／发布／回收失败及进程中断；恢复旧或新完整AuthoritativeTradingState，核对余额、库存、成本、费用、账本、占用、游标与摘要，缺段／摘要错误失败关闭，Unknown及accepted均零重发。
- [x] 记录OS／文件系统、源码树、artifact、schema、种子、命令和输入规模，验证格式／artifact身份不匹配失败关闭；记录小功能样本的RSS／峰值内存、队列水位、日志增长与恢复耗时，保留全部失败／未执行结果。
- [x] 按票01核对文件恢复语义和检查点义务；千单容量、压力、资源预算、索引成本及目标平台性能资格明确deferred／未测，小功能资源观察不称达标。Linux文件功能证据可独立交给Linux生产专项，不等待Windows票。
- [x] 不自动运行破坏性目标机断电、线上交易或凭证操作；WSL/开发 Linux 结果不替代目标节点持久化、性能或完整 Linux 生产资格。

## Evidence

2026-10-17：最终 `11-final-v6` 完成，115份源码SHA256 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`。
完整ReleaseSafe/Debug各623 passed、1指定IPC skipped、0 failed；应用和CLI各十轮/30新进程、两组物理审计、两模式各18故障拒绝及accepted/Unknown零重发通过；84项最终审计、130项源码包和独立双轴审查通过。
WSL1/lxfs真实adapter目录fsync共951次成功、无fallback，不授予目标掉电/性能或生产资格。历史失败、资源缺项与未执行项均保留。见[11证据](../11-evidence.md)与[独立Linux交接](../11-final-v6-linux-evidence/summary.md)。

## Out of scope

本次本地实现不包含部署、真实 Demo/Testnet/生产下单，也不自动授予平台或 Venue 生产资格。
