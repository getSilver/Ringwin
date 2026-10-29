# 08：代码替换与 ForwardRollback 创建 StrategySuccessor

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)
Parent: [模块地图](../map.md)

## Question

如何用新实例接替旧代码，并在回退时保留当前经济历史与权限边界？

## What to build

贯通候选验证、旧责任闭合、排空和StrategySuccessor切换；ForwardRollback作为新的正向切换。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] 代码改变创建新包/定义和新Successor；ForwardRollback复用旧定义内容但创建新的Successor，延续原VirtualPortfolio。
- [ ] 旧实例有活动周期、未完成订单、Unknown、未处理迟到事实或需管理仓位/残余时拒绝接替，不自动平仓。
- [ ] 责任闭合后采用Rebuild初始化新私有状态和从1开始的新意图空间；资金、经济历史和风险约束不重置。
- [ ] 版本激活持久事实与Host激活分别验证，旧输出被拒绝；成功切换停在Ready，排空后失败不自动复权。
- [ ] Web展示目标、新旧实际身份和结果；验收替换、正向回退及拒绝路径，新增中断点复用既有恢复规则。

## Answer / 实现证据

待实施。

