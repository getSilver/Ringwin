# 确定统一执行、事件顺序与时间模型

Type: grilling
Status: resolved
Blocked by: 02
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

如何使回测、仿真、实盘和故障重放使用一致且可复现的执行语义？

## Answer

- 订单簿、策略、风控、账户账本和 OMS 在回测、仿真及实盘中使用同一核心实现；只替换事件源、时钟和执行适配器。
- 策略不能直接读取系统时间、访问网络或直接修改账户状态；随机行为使用显式种子。
- 不设置热路径全局序列器。交易所连接保留 source_seq，TradingShard 生成 shard_seq，跨分片策略协调器记录 strategy_seq 和实际合并顺序。
- correlation_id 关联策略意图、风险决定、订单、回报和成交。
- 事件分别记录交易所 source_time、接收 receive_time、本机 monotonic_time 和审计 wall_time_utc。
- 本地排序和超时使用单调时钟；支持时采用 NIC 硬件时间戳及 PTP。
- 策略只接收已记录的 TimerEvent；回测由虚拟时钟生成同样事件。

## Comments

- 2026-07-25：初始设计访谈确认。
