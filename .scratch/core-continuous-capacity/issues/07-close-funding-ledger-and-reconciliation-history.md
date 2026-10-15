# 07: 贯通资金费、账本与对账历史归档

Type: task
Status: resolved
Assignee: Codex
Blocked by: [06 贯通成交与费用历史归档](06-close-fill-and-fee-archive.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何长期持仓跨多次资金费结算和对账继续运行，账本明细回收不丢失成本、PnL 或未解决差异？

## What to build

长期持仓跨多次资金费结算和对账继续运行，账本明细回收不丢失成本、PnL 或未解决差异。

## Acceptance criteria

- [x] 贯通资金费/结算、对账和账本历史的归档与恢复，保留当前经济状态及历史身份链。
- [x] 未解决 Suspense/ReconciliationBreak、待解释资金变化或仍需证据的事实不通过归档消失；重复 no-op，冲突失败关闭。
- [x] 归档前后 Portfolio/Exchange 余额、仓位、保证金、成本、Realized/UnrealizedPnL 及账本借贷守恒。
- [x] 验证跨多个结算周期、零订单但有持仓、混合资产费用与对账差异；不将测试输入解释为 Venue 协议资格。
- [x] 在归档/检查点/恢复边界注入故障，重放得到一致经济状态，不重复结算或发送。

## Evidence

2026-10-15完成，见[07证据](../07-evidence.md)与[双轴审查](../07-review.md)。96份源码SHA256为`a8c99fb7eed0cfa638d41caf0b1c37b42d8745a2447efab23bd6f29fd7235ccf`；完整Debug/ReleaseSafe串行各567/567，应用/CLI重建及各两个离线模式退出0，129项身份/日志/产物审计通过。复现入口为`run-07-final-acceptance.py`，复核入口为`audit-07-final.py 07-final-v5`。

覆盖完整资金费/ledger与零身份、十轮持仓及混合资产费用窗口、真正空窗口、缺证据与冲突失败关闭、归档/检查点/恢复故障及零重发。强制执行分配/ack未完成证据继续pin，归08处理。压力、资源与平台/Venue生产资格均未取得。

## Out of scope

本票实现不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
