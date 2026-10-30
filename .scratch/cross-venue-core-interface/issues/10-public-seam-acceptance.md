# 10：H1–H3 公共接缝综合验收

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 增量与重同步](03-depth-resynchronization.md)、[06 双 IOC 执行](06-dual-ioc-dispatch.md)、[07 原生 Post-only](07-native-post-only.md)、[09 周期恢复与激活](09-cycle-recovery.md)；相关策略行为与参数合同冻结
Parent: [模块地图](../map.md)

## Question

如何证明三项接口能共同支持策略，而不是分别通过孤立测试？

## What to build

使用冻结合同驱动可复现的策略测试消费者，串联公共行情、Host 双腿输出、共同准入、执行事实、checkpoint 与恢复；建立逐项证据矩阵。

## 完成条件

- [x] 记录相关策略行为、参数合同、状态 schema 和模型版本的冻结依据；测试值与真实部署/校准值明确区分。
- [x] 从 MarketFeedAdapter 和 Host 公共输入输出驱动整条路径，不以直接修改私有状态替代接口验收。
- [x] I1–I8、V2 与 S6-A–P 均映射到实际场景、命令、输入摘要、版本、崩溃切点及结果；缺失或失败明确列出。
- [x] 比较连续运行与恢复的可见盘口、策略摘要、意图/拒绝、预留、占用及唯一经济结果；覆盖混合异常而非仅正常路径。
- [x] H1/H2/H3 分别给出通过范围；完整组传输、核心共同准入和 Venue 执行证据分别记录。
- [x] Taker–Taker 与 Maker–Taker 分别记录资格。Post-only 与 L2 通过不能替代 maker 主动成交、队列可观测性及条件执行证据。
- [x] 平台和 Venue 证据不相互继承；离线通过不证明 Demo、生产或收益资格。未授权线上验证记为未执行。
- [x] 只在本模块同步完成证据与状态；不自动修改或关闭来源 spec，不以本模块完成替代整条策略资格。

## Answer

2026-10-30：按用户本次确认的Windows本机离线范围完成，见[冻结合同](../10-acceptance-contract.md)和[I1–I8、V2、S6-A–P证据矩阵](../10-verification.md)。实现`bec1ad4c`，审查修订`1b77d655`；真实深度→Python Host完整组→核心共同准入→两账户独立发送→报告/唯一Fill→文件checkpoint/RawIngress恢复→持久激活已贯通，连续与恢复状态一致，新开仓仍关闭。

最终Python245/245、ReleaseSafe819/819、Host产品28/28，独立退出码均0；产品第25项执行最终源码下的12个核心恢复场景。Standards与Spec独立复审无遗留发现。部署/校准参数、真实Venue、完整Maker模式、跨平台、生产及收益资格仍未取得；来源spec不修改或关闭，无部署或交易。
