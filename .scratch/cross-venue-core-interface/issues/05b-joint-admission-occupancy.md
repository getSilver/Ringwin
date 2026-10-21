# 05b：完整组共同准入与账户品种占用

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 权威边界](01-authority-boundary.md)、[04 Host 完整组](04-host-intent-group.md)、[05a 多账户权威表示](05a-multi-account-authority.md)
Parent: [模块地图](../map.md)

## Question

如何在一个权威事务内接受完整双腿组、建立资金预留和周期品种占用，并在失败时不留下半组？

## What to build

将 04 的完整 Host 候选贯通 05a 的多账户状态；遵守 [权威设计](../authority-design.md) 的身份、拒绝、容量与兼容合同，一次提交两腿风险、预留、周期键和命令事实。本票为 06/07 的共同准入前置，不声称 Venue 发送或成交原子性。

## 完成条件

- [x] 公共 Host → 核心 → Owner/Store 路径中，两成员账户/品种/组合/激活/配置和稳定连续身份整体校验；Python 不能提供风险、预留、命令或 ClientOrderId。
- [x] AB/AC 竞争同账户品种仅一组提交，失败组在其他账户无残留；所有新增周期入口遵守唯一 owner 占用。
- [x] 同账户跨品种共享资金覆盖可用 100、已占 70、再请求 40 的整体拒绝及请求 30 的边界；同组 60+50 拒绝，两账户资金不能互抵。
- [x] 任一腿风险、能力、资金、占用或容量不合格时无半组命令/预留；身份可验证的拒绝持久记录组和成员消费结果，重复/冲突及冷历史行为有证据。
- [x] 在全部 append/commit/发布边界故障后经 snapshot/restore/replay 核对组、命令、预留、占用与摘要；孤尾保持关闭，未 commit 不授予发送许可。
- [x] 覆盖最后容量槽、整数溢出、安全事实独立容量；Unknown 与未闭合经济引用保持 pin，订单终态不等于周期释放。覆盖 I2/I3 与 S6-E 核心部分。

## Answer

2026-10-22 resolved。在05a权威分区上完成真实Python Host完整双腿帧到共同候选、单Owner/Store提交、两账户命令与占用；单成员新周期及任一腿失败整组拒绝。AB/AC双到达顺序、100/70/40/30及60+50边界、全部10 append/4 commit与checkpoint发布故障、Unknown恢复不重发、终态不释放、撤单和并发减仓安全边界均有公共证据。

最终ReleaseSafe **683/683**、定向 **25/25**、真实Host文件恢复及Python **5/5**通过，双轴复审无遗留阻断；见[05验证记录](../05-verification.md)。I2/I3和S6-E仅关闭本票核心事实部分，Venue实际执行、真实模型与恢复激活仍分别归06/07/08/09/10。09a前活动订单/Fill保持pin；多账户产品入口、部署及生产资格继续关闭。
