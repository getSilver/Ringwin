# 建立单进程内存态 walking skeleton

Type: implementation
Status: resolved
Blocked by: 01
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

最少的 Zig 产品代码如何让一条固定行情事件穿过 TradingShard、原生示例策略、本地准入、OrderCommand、模拟 Venue 和执行事实并返回核心，而不先建设横向框架？

## Scope

- 建立一个 Zig 可执行入口和一个 TradingShard 实现。
- 使用直接、类型化的事件输入和命令输出；不引入通用 EventBus、插件注册表或依赖注入框架。
- 模拟 Venue 作为外围驱动消费 OrderCommand 并返回固定执行事实。
- 首先跑通第 01 票 happy path 的事件骨架；尚未完整的经济投影使用明确断言阻止被误认为完成。
- ReleaseSafe 下提供一条命令运行整个场景。

## Done when

- 从首个输入事件到最终执行事实只有一个可追踪调用/事件路径。
- 相同 fixture 连续运行得到相同事件类型和身份顺序。
- 没有真实网络、文件持久化、多线程或第二个 TradingShard。

## Answer

- 产品原型入口为 [`src/main.zig`](../../../src/main.zig)，不增加 build.zig、外部依赖或横向框架。
- 11 条 Genesis 事件、固定 L2 行情、TimerEvent、原生示例策略、风险接受、风险预留和 OrderCommand 全部穿过一个版本化 `TradingShard.handle` seam。
- SimVenue 只消费不可变 OrderCommand，并返回 Accepted、两笔 Fill、PartiallyFilled 和 Filled 回报；外围驱动把这些事实重新送入同一个 TradingShard seam。
- 单进程使用固定容量内存 trace；程序连续运行同一场景两次并逐事件比较 sequence、kind 和 identity。
- ReleaseSafe 自检得到 26 条稳定事件，最终 OrderState 为 Filled、累计成交 100 contracts。
- 当前代码显式断言 `economic_projections_complete = false`；订单账务、双层仓位、费用、PnL 与风险重算仍由下一张票负责，不能把 walking skeleton 误报为完整交易引擎。
- 验证命令：`zig run src/main.zig -O ReleaseSafe`、`zig fmt --check src/main.zig`、`zig test src/main.zig -O ReleaseSafe`。

## Comments

- 2026-07-30：已认领；开始实现最小单分片内存态 happy-path 骨架。
- 2026-07-30：ReleaseSafe walking skeleton 与确定性自检通过；票据解决。
