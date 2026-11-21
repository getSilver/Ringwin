# 08 从机会页将一条路线加入指定策略

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [06 在机会页给出可复算的交易潜力](06-evaluation.md)、[07 跨所策略以空交易名单启动](07-empty-list.md)
Parent: [模块地图](../map.md)

## Question

点击加入后核心究竟批准哪一条路线？

## What to build

在正常前端选择 StrategyInstance 与 VirtualPortfolio，将候选映射到部署账户和品种，回显核心回执。

## 验收条件

- [ ] 同币多路线中仅所选双腿、方向及模式进入指定策略名单。
- [ ] Demo × Testnet 分别映射各自环境、账户和品种；观察来源与真实账户可独立核对。
- [ ] 现行评估过期、映射缺失或批准被拒时显示原因，页面状态与核心一致。
