# 09: 贯通千单负载与安全背压

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [04 贯通多交易对观察与选择性交易](04-support-observation-and-selective-trading.md), [07 贯通资金费、账本与对账历史归档](07-close-funding-ledger-and-reconciliation-history.md), [08 贯通控制与账户协调历史回收](08-reclaim-control-and-account-coordination-history.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何在多组合、多策略类别和共享账户下，每分片同时持有 1,024 个存活订单，压力达到合同边界时仍能处理必要安全事实？

## What to build

在多组合、多策略类别和共享账户下，每分片同时持有 1,024 个存活订单，压力达到合同边界时仍能处理必要安全事实。

## Acceptance criteria

- [ ] 四分片同时达到各自 1,024 个存活订单；500 个观察组合中仅部分做市，混入双腿开平仓与对冲的合成意图，不实现三套策略。
- [ ] 待归档终态在合同预算内与存活订单共存；Gateway、账户协调、Adapter 输出、资产投影、快照和计数类型没有未声明的小容量瓶颈。
- [ ] 覆盖均衡与热点分片、部分 Venue 无订单、Unknown、PendingCancel、归档积压及回报突发；不以总槽位余量掩盖单分片满载。
- [ ] 新单满载时仍有已冻结的回报、撤单、对账及故障事实余量；超合同负载背压或撤权，不丢事实/覆盖状态/错误释放占用。
- [ ] 测量复制/索引/栈、峰值内存、队列水位和延迟，对照票 01 预算；仅按证据修改布局，不通过清空历史或关掉校验达标。
- [ ] 保留可复现混合负载、故障输入和 Debug/ReleaseSafe 结果，恢复订单、账本、占用及摘要一致；开发机结果不授予目标平台性能资格。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
