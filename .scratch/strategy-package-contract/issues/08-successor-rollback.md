# 08：代码替换与 ForwardRollback 创建 StrategySuccessor

Type: task
Status: resolved
Assignee: Codex
Blocked by: [06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)
Parent: [模块地图](../map.md)

## Question

如何用新实例接替旧代码，并在回退时保留当前经济历史与权限边界？

## What to build

贯通候选验证、旧责任闭合、排空和StrategySuccessor切换；ForwardRollback作为新的正向切换。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] 代码改变创建新包/定义和新Successor；ForwardRollback复用旧定义内容但创建新的Successor，延续原VirtualPortfolio。
- [x] 旧实例有活动周期、未完成订单、Unknown、未处理迟到事实或需管理仓位/残余时拒绝接替，不自动平仓。
- [x] 责任闭合后采用Rebuild初始化新私有状态和从1开始的新意图空间；资金、经济历史和风险约束不重置。
- [x] 版本激活持久事实与Host激活分别验证，旧输出被拒绝；成功切换停在Ready，排空后失败不自动复权。
- [x] Web展示目标、新旧实际身份和结果；验收替换、正向回退及拒绝路径，新增中断点复用既有恢复规则。

## Answer / 实现证据

2026-11-01：完成现有签名发布安装路径上的Web接替与ForwardRollback、新候选Host无权Rebuild、原生责任闭合校验和持久版本激活。每次接替分配新实例身份、独立checkpoint与从1开始的意图空间，保留原VirtualPortfolio、配置、资金、经济历史、预算及风险约束；成功停Ready，EnableTrading与实际HostActivated应用ACK独立。旧身份被封住，排空后未知结果不能恢复旧实例。支持命令内容冲突拒绝与跨连续接替、后端重开的幂等结果。

最终Windows Python全量320项，306通过、14平台skip，退出码0；ReleaseSafe核心824/824，退出码0；原生构建9/9、最终验收节点构建3/3、核心专项4/4，UI与静态检查通过。Standards无发现，Spec的连续接替后幂等结果问题已修正并复审无剩余发现。编辑器崩溃的中断日志保留，重跑全量独立记录退出码，源码/二进制SHA-256无漂移。详见[08验证说明](../evidence/08-validation.md)。

边界：单Host与DecisionDomain排空范围保留；驻留身份/fence容量耗尽时拒绝后续接替，未引入身份归档扩展。未执行Linux资源、真实Venue、Demo、部署或生产资格验收；地图仍open，09/10可接手但未认领。

