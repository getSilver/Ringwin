# 确定订单领域与恢复语义

Type: grilling
Status: resolved
Blocked by: 05, 06
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

订单生命周期如何建模，发送结果不确定或进程崩溃后如何安全恢复？

## Answer

- 使用 OrderIntent、OrderCommand、Order 和 ExecutionReport 四个不同概念。
- OrderIntent 是策略愿望；风控接受后形成 OrderCommand；OMS 拥有 Order 状态；交易所事实以 ExecutionReport 输入。
- 仓位和资金只由成交与账户事实改变，不能由意图或本地发送成功改变。
- 订单状态至少包含 PendingSubmit、Unknown、Live、PartiallyFilled、PendingCancel、Filled、Canceled 和 Rejected。
- 每个订单在发送前获得永久唯一 client_order_id 和递增 revision，并建立风险预留。
- 发送超时进入 Unknown，禁止盲目重发；先使用 client_order_id 查询交易所，确认不存在后才可重试。
- 重启时先对账未完成订单、近期成交、余额和仓位；对账完成前只允许撤单及降低风险。
- 首版订单热路径不执行同步 fsync；安全性依赖幂等标识、状态机和交易所对账。

## Comments

- 2026-07-25：初始设计访谈确认。
