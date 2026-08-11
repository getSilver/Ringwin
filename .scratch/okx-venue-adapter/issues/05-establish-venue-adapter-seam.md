# 建立 Venue Adapter seam 并保留 SimVenue

Type: task
Status: resolved
Assignee:
Blocked by: 03
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何以最小产品代码建立已冻结的 Venue Adapter interface，把现有 SimVenue 移到该 seam 后面，并保持所有既有确定性、失败轨迹、日志重放和 Python StrategyHost 验收不变？

## Answer

- 新增 [`src/venue_adapter.zig`](../../../src/venue_adapter.zig)，以一个运行时 fat pointer 暴露冻结的四操作 `start`、`trySend`、`tryDrain`、`stop(DrainDeadline)`；每个操作使用明确错误集，调用方不观察具体 Adapter implementation。
- 当前 `AdapterRequest` 只承载已有 `OrderCommand`，`AdapterOutputBatch` 只承载当前所需的本地 dispatch fact 与有序 ingress；没有为未来 Venue 添加注册表、工厂、通用请求或插件框架。
- 原 `SimVenue.execute` 已规范命名为 `SimulatedVenue` 并移到 seam 后面。它使用容量 1、无分配的 pending output slot：第二次 `trySend` 返回 `backpressure`，未 drain 时 `stop` 返回 `OutputPending`，stop 后新增请求返回 `stopped`；产品场景不再直接调用模拟执行函数。
- happy path 与 duplicate report 均经 VenueAdapter 产生原有 `order_dispatched`、ExecutionReport 与 Fill。原 31/23/18/23/33 事件轨迹、五个固定 digest、journal recovery、Unknown 对账和幂等投影保持不变。
- 新增 seam 合同测试；Zig Debug、ReleaseSafe、ReleaseFast 均 6/6 通过，`zig run src/main.zig -O ReleaseSafe` 自检通过，Python StrategyHost 14 步功能/故障/恢复/容量验收通过。
- [`CONTEXT.md`](../../../CONTEXT.md) 新增规范词 `VenueAdapter`；README 已记录当前能力波次和格式检查入口。OKX implementation、线程与 libcurl 生命周期留给后续票据，不进入本次 seam。
