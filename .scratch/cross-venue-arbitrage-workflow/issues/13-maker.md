# 13 Maker 撤换单、增量对冲与恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [11 从前端批准跑通双 IOC 完整周期](11-dual-ioc.md)
Parent: [模块地图](../map.md)

## Question

Maker 撤中成交后策略如何只对冲真实增量？

## What to build

将 Maker 报价、撤换、成交及对冲关联至同一周期和原订单，支持任一腿作 Maker。

## 验收条件

- [ ] 两种 Maker 腿分别完成报价、部分成交、撤换与退出；撤单建议可到达对应 Gateway。
- [ ] 撤中成交时结合已应用成交和在途对冲计算净增量。
- [ ] 撤单结果未知或重启后按原身份恢复，核对迟到成交、最终敞口及账务。
