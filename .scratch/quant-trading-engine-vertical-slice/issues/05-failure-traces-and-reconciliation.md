# 实现缺口、拒绝、Unknown 与幂等失败轨迹

Type: implementation
Status: resolved
Blocked by: 04
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

首个闭环如何证明异常不是旁路逻辑，而是与 happy path 使用相同核心状态机、日志和投影规则？

## Scope

- L2 序号缺口进入不健康状态并阻止新增风险，重同步事件恢复健康。
- 风险拒绝产生稳定 CanonicalRejectReason，且不生成可发送命令。
- 模拟网关注入 Submitted 后结果不明，订单进入 Unknown 并保留最坏风险占用。
- 对账以 ConfirmedAbsent 或确定终态事实结束 Unknown；不根据超时猜测。
- 重复接受、成交、取消或对账事实按稳定经济身份幂等处理。

## Done when

- 第 01 票四条失败轨迹均由同一个可执行程序自动检查。
- 每条失败轨迹实时运行与日志重放等价。
- 任意重复回报都不会重复改变数量、余额、费用或 PnL。

## Answer

- [`src/main.zig`](../../../src/main.zig) 的同一 TradingShard 状态机现支持 MarketHealth `Initializing/Healthy/Gap`、稳定拒绝原因、OrderState Unknown、FoundLive 对账及 Fill/ExecutionReport 幂等事实集合。
- `market-gap-v1` 共 23 条事实：缺口 delta 被记录但不应用，市场进入 Gap；TimerEvent 仍产生 OrderIntent，风险以 `MarketDataGap` 拒绝且不产生 OrderCommand；snapshot 200 + delta 201 恢复 Healthy。实时/重放固定摘要为 `e857b9c12bdea00ea176249c2c8686057b0c618ef60ad7b111df05efbdeda5d4`。
- `risk-rejection-v1` 共 18 条事实：`100,001 @ 50,100.0` 选择第二档，所需额度精确为 `11,397.863978 USDT`，以 `GlobalRiskLeaseExceeded` 拒绝；不建立 Order、预留或 dispatch。固定摘要为 `b5fe808878d1394479092619a00a99c562c3a89f111de3d4a79964e7045caebd`。
- `unknown-reconciliation-v1` 共 23 条事实：唯一发送尝试进入 Unknown 并保留 `11.397750 USDT` 预留；按原客户端订单号得到 FoundLive 和 Accepted 后恢复 Live，不创建第二命令。固定摘要为 `a61e0e5e863601fe44daf55806a506591ec7c6081216000ebda8c5e0686c029c`。
- `duplicate-report-v1` 共 33 条事实：重复 `sim-fill-1` 与 partial report 各自进入日志，但不产生第二笔账务事务或风险调整；最终经济状态与 happy path 完全一致。固定摘要为 `7bb91e2c0f375481a7d62f772ac68953dc0b97fcb913ba994a53ce01ae3d0040`。
- 幂等集合按稳定事实身份排序并保存完整经济字段；同一身份、不同内容以 ConflictingFillIdentity/ConflictingReportIdentity 失败关闭。
- 额外自动检查重复 FoundLive 对账与重复 Canceled ExecutionReport：首次取消释放预留，重复取消只追加事实，不再次改变风险或经济状态。
- 五条权威轨迹全部使用相同稳定日志和 ReplayDriver；`zig test src/main.zig -O ReleaseSafe` 执行全部轨迹、摘要、禁止行为、日志恢复及幂等检查。

## Comments

- 2026-07-30：已认领；开始实现 market gap、risk rejection、Unknown reconciliation 与 duplicate report 四条权威失败轨迹。
- 2026-07-30：四条失败轨迹及重复取消/对账检查全部通过实时与重放验收；票据解决。
