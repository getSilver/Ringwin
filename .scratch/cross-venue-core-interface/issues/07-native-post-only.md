# 07：原生 Post-only 从 Host 到 Venue 的能力校验

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 共同准入与持久占用](05-joint-admission.md)
Parent: [模块地图](../map.md)

## Question

如何使 maker 请求明确要求原生 Post-only，并在整条执行链拒绝不等价替代？

## What to build

核对并复用已有规范 Post-only 语义，贯通 Host 表达、组准入、版本化能力检查、命令及 VenueAdapter 映射。

## 完成条件

- [x] 公共 Host 输出到适配器契约证明原生 Post-only 要求不丢失；普通 GTC 不能满足该要求。
- [x] 目标 Venue/产品/账户/环境能力缺失、不适用或失效时拒绝；不能静默降级或由适配器自行模拟。用户于2026-10-22确认本票按版本、规则、会话失效及命令期限验收；能力声明没有独立 TTL，不会因长期未更新而自行到期。
- [x] 发送时复核资格；记录准入前后能力变化时命令、预留和已提交事实的安全处理。
- [x] 持久捕获与重放保留能力要求及版本，恢复不能将 Post-only 改成 GTC。
- [x] 分别记录传输、核心准入、适配器契约和实际 Venue 证据；不据此声称队列位置、成交率、对冲收益或完整 Maker–Taker 资格。

## Answer

2026-10-22完成离线验收。Host新增明确的原生Post-only表达，单意图和完整组转换保留要求，复用既有共同准入、能力版本、发送复核及持久证明。能力撤销后仍允许使用当前权限显式撤销已有maker，不提前释放预留或周期。

最终ReleaseSafe **699/699**，修正场景定向 **3/3**，真实Python Host的GTC/Post-only多账户文件关闭重开与既有单/组路径通过；Python **5/5**、**7/7**通过，Standards/Spec复审无遗留发现。实现合同、命令、故障证据及资格边界见[验证记录](../07-verification.md)。

本票不授权真实或Demo下单，未取得任何实际Venue或完整Maker–Taker资格；没有独立能力TTL，活动周期释放及完整策略恢复仍归09/10。
