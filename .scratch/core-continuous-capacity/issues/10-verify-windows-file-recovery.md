# 10: 验证 Windows 文件持久化与持续恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: [09 贯通千单负载与安全背压](09-qualify-live-order-capacity-and-backpressure.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何Windows文件适配器承载小规模真实核心业务，在多轮归档和进程重启后恢复正确状态，形成独立的文件功能证据？

## What to build

Windows文件适配器承载小规模真实核心业务，在多轮归档和进程重启后恢复正确状态；原平台容量与资源目标保留为未测设计参考。

## Acceptance criteria

- [x] 在Windows真实FileAdapter运行票09的小规模公共业务链，每个夹具跨全部分片live和terminal总量分别不超过100；贯通输入、发送前屏障、归档、快照、文件重开及新进程恢复，不用内存快照冒充文件恢复，禁止千单容量／压力测试。
- [x] 注入写入／同步／发布／回收失败及进程中断；恢复旧或新完整AuthoritativeTradingState，核对余额、库存、成本、费用、账本、占用、游标与摘要，缺段／摘要错误失败关闭，Unknown及accepted均零重发。
- [x] 记录OS／文件系统、源码树、artifact、schema、种子、命令和输入规模，验证格式／artifact身份不匹配失败关闭；记录小功能样本的RSS／峰值内存、队列水位、日志增长与恢复耗时，保留全部失败／未执行结果。
- [x] 按票01核对文件恢复语义和检查点义务；千单容量、压力、资源预算、索引成本及目标平台性能资格明确deferred／未测，小功能资源观察不称达标。Windows文件功能证据可独立交给Windows生产专项，不等待Linux票。
- [x] 不自动运行破坏性目标机断电、线上交易或凭证操作；本票不证明断电耐久性、转储保护、外部 NodeFence 或完整 Windows 生产资格。

## Evidence

2026-10-16完成，基线4ea4c3ee，最终114源码f1e1a54a。见[完整证据与五条AC对应表](../10-evidence.md)、[Windows交接包](../10-final-v3-windows-evidence/summary.md)、[570项审计](../10-final-v3-audit.json)。同源完整Debug/ReleaseSafe各624/624，实际64MiB app/256MiB CLI构建和各两个离线模式退出0；两产物各十轮/30个新进程，包含真正500组合/三类别、混合生命周期及共享账户；恢复完整经济、账本、占用和游标，accepted/Unknown零重发。两mode各18场景与两产物各2次精确阶段终止通过。资源、身份、失败及not_run均已封存。

实现修复了从未发布历史时双sidecar缺省被误关门，以及Owner/Replacement无须candidate分支预留大栈帧；事务后半及rollback保持原样。夹具仅对真实新发布checkpoint，未放宽空归档验证。失败候选源码zip、原始日志及数据保留。独立Standards/Spec未发现剩余确认P1/P2。

普通文件sync/replace/reopen功能通过；目录FlushFileBuffers实际两次失败error5，目录/断电耐久性继续unqualified。完成的是独立Windows小规模文件功能证据，不授生产资格；Linux票11和最终双平台交接票12未执行。

## Out of scope

实现不包含部署、真实 Demo/Testnet/生产下单、凭证或破坏性断电，
也不自动授予平台或 Venue 生产资格。千单容量、压力、资源预算、索引成本及目标平台性能仍deferred／未测。
