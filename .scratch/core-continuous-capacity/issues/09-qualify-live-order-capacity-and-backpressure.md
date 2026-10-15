# 09: 贯通千单负载与安全背压

Type: task
Status: resolved
Assignee: Codex
Blocked by: [04 贯通多交易对观察与选择性交易](04-support-observation-and-selective-trading.md), [07 贯通资金费、账本与对账历史归档](07-close-funding-ledger-and-reconciliation-history.md), [08 贯通控制与账户协调历史回收](08-reclaim-control-and-account-coordination-history.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何在多组合、多策略类别和共享账户下，用小夹具验证全部订单与安全背压功能，同时保留每分片1,024存活订单的未测设计目标？

## What to build

在多组合、多策略类别和共享账户下，以小夹具与纯边界谓词验证订单、计数边界及安全事实处理；本轮不执行千单容量或压力负载，原目标仍作为后续资格参考。

## Acceptance criteria

- [x] 四分片以小功能夹具验证三个策略类别的合成意图；每个夹具跨全部分片的live总量和terminal总量分别不超过100，500观察组合中仅部分做市，保留双腿开平仓与对冲，不实现三套策略。禁止构造千单或运行容量／压力测试；每分片1,024目标仅为未测设计参考。
- [x] 小夹具中待归档终态与存活订单共存；盘点并验证Trace、OMS、Gateway、账户协调、Adapter输出、资产与经济投影、控制事实、canonical ingress、快照及Store／manifest的计数类型、身份回收和失败关闭边界。满额数字只用纯边界谓词检查，不填满生产数组或伪造大批发送证明。
- [x] 小夹具覆盖均衡与热点分片、部分Venue无订单、Unknown、PendingCancel、部分成交、归档积压和回报批次；分别核对单分片与共享账户归属，不用全局余量掩盖分片边界错误。
- [x] 用小夹具与纯边界谓词验证新增风险关闭／背压时，回报、撤单、对账及故障事实仍可处理；事实不可接受时保留可重试输入并撤权，不丢事实、覆盖状态或错误释放占用。原队列余量与吞吐目标未作满载验证。
- [x] 记录小功能运行的复制／索引／栈、RSS／峰值内存、队列水位与延迟观察，明确样本规模及失败／未测项；不宣称满足票01的千单资源预算、索引成本或平台性能，不通过清空历史或关闭校验取得结果。
- [x] 保留可复现输入、种子、故障与Debug/ReleaseSafe结果，通过公共业务链验证订单、完整经济状态、账本、占用及摘要恢复一致、Unknown与accepted零重发；千单容量、压力与目标平台性能资格明确deferred。

## Evidence

2026-10-16小规模功能验收完成，见[09证据](../09-evidence.md)、[计数边界盘点](../09-boundary-inventory.md)和[独立双轴审查](../09-review.md)。基线0779b48e；最终110源码身份7d70c32a，完整Debug/ReleaseSafe串行各616/616，应用64MiB/CLI256MiB重建及两个离线模式均退出0，独立功能样本9/9，131项封存审计通过、source drift0。

三类别真实spot/perpetual和跨Venue独立发送/Fill/恢复、四片十轮非零经济接管、共享账户真实ceiling、安全背压与冷dispatch零重发均由公共接口验证。最初会话进程中断的片段保留且不计通过。资源观察如实记录：独立样本peak911.96MiB，完整RS/Debug测试进程1127.20/1223.23MiB，Owner显式结构复制45,324,448B；实际栈峰值、物理索引成本和千单/压力/目标平台性能仍未取得。本票关闭只表示小规模功能合同完成。

## Out of scope

实现不包含部署、真实 Demo/Testnet/生产下单，也不授予平台或Venue生产资格。
后续Frontier为10/11，分别执行独立平台文件恢复验收；本次没有提前执行。
