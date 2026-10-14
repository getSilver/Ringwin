# 11: 验证 Linux 文件持久化与持续恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [09 贯通千单负载与安全背压](09-qualify-live-order-capacity-and-backpressure.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何Linux文件适配器承载同一小规模核心业务，在多轮归档和进程重启后恢复正确状态，形成独立的文件功能证据？

## What to build

Linux文件适配器承载同一小规模核心业务，在多轮归档和进程重启后恢复正确状态；原平台容量与资源目标保留为未测设计参考。

## Acceptance criteria

- [ ] 在Linux真实FileAdapter运行票09的同一小规模公共业务链，每个夹具跨全部分片live和terminal总量分别不超过100；贯通输入、发送前屏障、归档、快照、文件重开及新进程恢复，交叉编译不能替代运行结果，禁止千单容量／压力测试。
- [ ] 注入写入／同步／发布／回收失败及进程中断；恢复旧或新完整AuthoritativeTradingState，核对余额、库存、成本、费用、账本、占用、游标与摘要，缺段／摘要错误失败关闭，Unknown及accepted均零重发。
- [ ] 记录OS／文件系统、源码树、artifact、schema、种子、命令和输入规模，验证格式／artifact身份不匹配失败关闭；记录小功能样本的RSS／峰值内存、队列水位、日志增长与恢复耗时，保留全部失败／未执行结果。
- [ ] 按票01核对文件恢复语义和检查点义务；千单容量、压力、资源预算、索引成本及目标平台性能资格明确deferred／未测，小功能资源观察不称达标。Linux文件功能证据可独立交给Linux生产专项，不等待Windows票。
- [ ] 不自动运行破坏性目标机断电、线上交易或凭证操作；WSL/开发 Linux 结果不替代目标节点持久化、性能或完整 Linux 生产资格。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
