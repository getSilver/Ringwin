# 06: 贯通成交与费用历史归档

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [05 贯通终态订单与发送证据归档](05-close-order-and-dispatch-archive.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何已应用成交和费用明细安全归档后，系统继续处理新成交，且累计成交、余额和历史幂等在恢复后保持一致？

## What to build

已应用成交和费用明细安全归档后，系统继续处理新成交，且累计成交、余额和历史幂等在恢复后保持一致。

## Acceptance criteria

- [ ] 保留每单累计唯一已应用成交量和历史内容身份；明细回收不能令累计量归零，也不能借用 OMS reported cumulative 代替。
- [ ] report/Fill 任意合法先后、部分成交、多次手续费及第三资产费用经过核心和持久化恢复闭合。
- [ ] 跨归档边界的重复 Fill/费用无经济副作用，冲突失败关闭；不能因热单已移出而丢失归属验证。
- [ ] 归档前后余额、库存、成本及相关账本逐原子一致；故障时不提交部分经济状态。
- [ ] 小容量下连续跨多个证据窗口，通过公共 CanonicalEvent、snapshot/replay 和文件无关持久 seam 验证崩溃恢复、旧事实查证和零重发。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

本次仅发布任务，不实施代码。后续任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
