# 06: 贯通成交与费用历史归档

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 贯通终态订单与发送证据归档](05-close-order-and-dispatch-archive.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何已应用成交和费用明细安全归档后，系统继续处理新成交，且累计成交、余额和历史幂等在恢复后保持一致？

## What to build

已应用成交和费用明细安全归档后，系统继续处理新成交，且累计成交、余额和历史幂等在恢复后保持一致。

## Acceptance criteria

- [x] 保留每单累计唯一已应用成交量和历史内容身份；明细回收不能令累计量归零，也不能借用 OMS reported cumulative 代替。
- [x] report/Fill 任意合法先后、部分成交、多次手续费及第三资产费用经过核心和持久化恢复闭合。
- [x] 跨归档边界的重复 Fill/费用无经济副作用，冲突失败关闭；不能因热单已移出而丢失归属验证。
- [x] 归档前后余额、库存、成本及相关账本逐原子一致；故障时不提交部分经济状态。
- [x] 小容量下连续跨多个证据窗口，通过公共 CanonicalEvent、snapshot/replay 和文件无关持久 seam 验证崩溃恢复、旧事实查证和零重发。

## Evidence

2026-10-14功能验收完成。源码`c508f89c8c6faae0c428e3e2195df957d4377a453a673ee772edec2c9d2b17b4`，完整Debug/ReleaseSafe串行各551/551退出0；应用64MiB及CLI256MiB重建和两项离线模式全部退出0，逐步源码无漂移。独立Standards/Spec无剩余具体P1/P2，12条命令及产物/日志身份46项核对通过。

独立累计与归档量等式、完整费用/账本资格、热/冷same/conflict、十轮部分成交、第三资产fee/rebate、连续订单/成交业务根、故障恢复及SDK零重发均有公共回归。应用恢复及文件栈溢出已在保持生产容量和64MiB应用栈的条件下修复。

完整命令、源码/产物身份、逐项对应及旧失败/未测边界见[06证据](../06-evidence.md)、[审查](../06-review.md)。本票仅为每类live/terminal总量不超过100的功能闭合，不授予千单压力、资源/RSS/索引成本、Venue在线或平台生产资格。用户要求关闭06后停止，本代理不实施07。

## Out of scope

本任务实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
