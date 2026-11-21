# 12 双 IOC 单腿失败与重启恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [11 从前端批准跑通双 IOC 完整周期](11-dual-ioc.md)
Parent: [模块地图](../map.md)

## Question

双腿结果不一致或回报未知时如何恢复净敞口？

## What to build

按原周期与原订单查询并处理部分成交、拒绝及 Unknown，重启后从持久事实恢复。

## 验收条件

- [ ] 一腿部分成交另一腿拒绝，按实际成交量修复，核对最终敞口。
- [ ] 处理中重启、迟到或重复回报不产生重复下单、重复对冲和费用。
- [ ] 待确认状态能在原身份下解决或显式保留；对齐最终仓位、原币费用及汇差。
