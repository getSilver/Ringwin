# 把批事件与 OrderIntent 接入 TradingShard

Type: implementation
Status: resolved
Blocked by: 03
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

如何在不改变现有核心状态转换的前提下，把订阅事件批量发布给 Host，并把返回 OrderIntent
作为版本化输入重新进入 TradingShard 的身份、新鲜度、授权、定点风险和日志路径？

## Done when

- 订阅合并只复制 Host 实际需要的不可变事件，不全量广播。
- Python intent 通过与原生 intent 相同的风险、订单和事实投影，不存在测试或回测旁路。
- 旧 session、错误 cursor、未知 schema、重复/冲突身份和超过 100 ms 的 intent 稳定拒绝。

## Activity

- 2026-07-31：已认领；实现只允许在现有 `TradingShard` 的 OrderIntent 输入 seam
  重新进入核心，复用当前定点风险、订单状态、日志和投影，不为 Python、测试或回测
  建立第二条交易路径。
- 2026-07-31：已完成。`strategy_host_gateway.zig` 按 Host 内订阅并集只编码实际订阅事件，
  并在 SPSC 成功发布后才登记可引用的批次；冻结的 `OrderIntentV1` 在进入核心前重新校验
  session、schema、activation、cursor、100 ms 新鲜度、定点字段和 intent 身份。
- 2026-07-31：原生 timer intent 与 Python intent 都调用 `TradingShard.submitOrderIntent`，
  共用同一套定点风险、reservation、order command、事实日志与派生投影。真实 Python
  子进程通过 Zig 共享内存桥完成往返，并验证 duplicate、conflict、旧 session、错误
  cursor、未知 schema、未授权 activation 和 stale 七类拒绝均不进入风控。
- 2026-07-31：验收证据为 `zig test src\main.zig -O ReleaseSafe`（5/5）、
  Windows `strategy_host_integration`（accepted=1、stable_rejections=7、重放等价）及
  `zig build-exe src\strategy_host_integration.zig -target x86_64-linux-gnu
  -fno-emit-bin -O ReleaseSafe`。README 已记录可复现命令。
