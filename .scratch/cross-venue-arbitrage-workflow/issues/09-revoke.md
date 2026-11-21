# 09 从策略页查询和撤销持久批准

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [07 跨所策略以空交易名单启动](07-empty-list.md)
Parent: [模块地图](../map.md)

## Question

候选或 Web 会话消失后如何管理批准？

## What to build

从策略页按核心持久身份读取有效名单、请求回执并撤销，可用预先存在的核心批准验收。

## 验收条件

- [ ] 停扫描、退市和 Web 重启后均能找到并撤销原批准。
- [ ] 对丢失回执的请求按原身份查询或重试，回执及名单一致。
- [ ] 有效状态和历史回执分别管理；历史容量满仍可撤销，新开仓立即受限。
