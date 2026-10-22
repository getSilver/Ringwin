# 以同一实现验证四分片容量与隔离

Type: benchmark
Status: resolved
Blocked by: 06
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

同一 TradingShard 实现实例化四次后，是否保持确定性、定向行情扇出、独立过载和可接受的 P99，而不复制共享外围或引入共享可变交易状态？

## Scope

- 四个实例使用独立 DecisionDomain、序号、状态、队列和日志流。
- 行情规范化一次，只向订阅该品种的分片投递不可变事件。
- Execution Gateway 和全局风险额度分配保持共享外围职责。
- 注入一个分片的慢策略、行情缺口和队列饱和，验证其他分片继续满足健康与顺序合同。
- 比较单分片与四分片的吞吐、P99、缓存/队列开销和内存增长。

## Done when

- 四个分片分别重放得到各自相同 StateDigestV1。
- 一个分片过载不会改变其他分片的事件顺序或阻塞其安全事件。
- 性能退化有测量依据；若不可接受，优先修正路由、扇出和归属，不复制 Data/Execution 模块。

## Activity

- 2026-07-30：已认领；开始复用同一 `TradingShard` 实现验证四分片定向扇出、独立状态/日志、过载隔离及相对单分片性能。
- 2026-07-30：四分片确定性与故障隔离通过；Windows 2C/4T 节点的 2M/s 四分片延迟资格失败，原因和下一项最小资格环境已记录，票据解决。

## Answer

[`src/main.zig`](../../../src/main.zig) 继续只保留一个 `TradingShard` 实现，并新增
`--benchmark-four-shard` / `--benchmark-four-shard-raw`：

- 一个共享生产者把每条标准化行情事件只构造一次，再按 `DecisionDomain`
  定向写入四条独立的 4,096-entry SPSC 队列；没有全局事件总线或全量广播。
- 四个 worker 分别拥有自己的 `TradingShard`、序号、日志、队列、直方图和状态；
  队列是共享外围与单写者分片之间唯一的可变边界。
- Execution Gateway 和全局风险额度分配没有复制进分片；本原型只保留各一份共享外围职责，
  本票的行情性能路径不伪造网络或 Venue 执行。

### 可重复命令

```powershell
zig test src\main.zig -O ReleaseSafe
zig build-exe src\main.zig -O ReleaseFast '-femit-bin=.scratch/four-shard-benchmark.exe'
1..3 | ForEach-Object { .\.scratch\four-shard-benchmark.exe --benchmark-four-shard }
.\.scratch\four-shard-benchmark.exe --benchmark-four-shard-raw
```

环境与上一票相同：Windows 10 Enterprise LTSC `10.0.17763`、Intel i5-4200U
`2C/4T @ 1.60 GHz`、Zig `0.17.0-dev.315+5b647b792`、`ReleaseFast`。
这台机器没有“4 个分片专用物理核 + 至少 1 个共享路由/I/O 核”，所以结果只回答开发回归，
不授予生产资格。

### 确定性与隔离

- 四个 DecisionDomain 的 happy path 分别实时运行和重放，均得到
  `9951db6c2ea314b42fa0ce5887225cb4d026a95358b2ca026984dc59330adb08`。
- 定向扇出检查证明一个标准事件只进入订阅分片；其他三个分片的序号、状态和日志不变。
- 分片 0 被注入行情 Gap，随后把表示慢策略等待的 TimerEvent 留在队首并填满本地队列；
  第九次入队稳定返回 `ShardQueueFull`。
- 分片 1–3 在分片 0 停滞期间仍分别按序处理连续行情，保持 Healthy，日志各新增一条；
  分片 0 的 Gap 和饱和没有传播。

`zig test src\main.zig -O ReleaseSafe` 自动执行上述检查。

### 三轮 2M events/s 开环结果

每个分片 1,000,000 样本；共享生产者按独立计划时间聚合发送 2,000,000 events/s，
迟发后继续追赶而不制造 coordinated omission。延迟从实际入队到处理完成；生产者计划迟发单独报告。

| 轮次 | 单分片参考 P99 | 四分片合并 P99 | P99.9 | 聚合吞吐 | 生产者最大迟发 | 队列满观察 |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 1 us | 1,642.5 us | 5,607.5 us | 1,998,508/s | 1,899.7 us | 1 |
| 2 | 1 us | 961 us | 2,699 us | 1,998,654/s | 649.4 us | 0 |
| 3 | 1 us | 2,347.5 us | 5,413.5 us | 1,998,654/s | 1,095 us | 0 |

所有分片均为 `overflow=0`、`correctness_failures=0`，但三轮 P99 均远高于
10 us；第一轮还达到队列满容量，因此整组四分片容量资格失败，不能由接近 2M/s 的吞吐抵消。

一次完整原始直方图保存在
[`benchmarks/07-four-shard-windows-raw.txt`](../benchmarks/07-four-shard-windows-raw.txt)，
SHA-256 `3D4A21D6AB37998F16F64DA35A8044C47E1256FD4B28730DD63968A66DAE822D`。
该次运行也如实保留了 `83.9933 ms` 生产者迟发、25 次队列满观察和
`4,257.5 us` 合并 P99，未挑选较好窗口替代。

### 内存、队列与结论

每分片资格 lane 的静态拥有内存为 `805,656 B`，四份为 `3,222,624 B`：

- `TradingShard`：`2,384 B`
- 决策日志段：`16,416 B`
- 4,096-entry SPSC：`458,784 B`
- 固定直方图：`328,024 B`

因此线性增长主要来自资格用队列和直方图，不是权威交易状态，也没有复制 Data Engine
或 Execution Gateway。Windows 无可用的生产等价硬件 cache counter，本票不编造 cache-miss
数字；静态 footprint、队列水位和 P99 已保留，Linux 资格运行再采集 cycles/event 与 cache miss。

结论是：**四分片确定性、定向扇出和故障隔离通过；当前节点的四分片容量/延迟资格失败。**
已测瓶颈来自 2C/4T 上五个活跃线程的调度迟发、追赶突发和队列等待，不支持复制共享模块，
也没有证据要求修改定点业务核心。下一项最小修正是在至少 5 个可独占物理核的约定 Linux
基线上固定 4 个分片核及共享路由核后重跑；若该环境仍超标，再剖析路由、扇出与分片归属。
