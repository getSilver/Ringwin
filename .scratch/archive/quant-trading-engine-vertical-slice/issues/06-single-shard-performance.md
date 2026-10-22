# 测量并收敛单分片端到端性能

Type: benchmark
Status: resolved
Blocked by: 05
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

完整单分片路径在真实业务检查、日志 enqueue 和可观测性开启时的 P50、P99、P99.9、吞吐及队列水位是多少，瓶颈是否来自必要工作？

## Scope

- 测量行情输入到策略完成，以及 OrderIntent 到可发送 OrderCommand 两条内部路径。
- 强制包含定点风险、订单投影、必要日志 enqueue 和最低生产遥测；排除交易所网络往返。
- 分别运行稳态、行情突发、订单突发和异常恢复负载。
- 先剖析再修改；不为未测瓶颈引入对象池、lock-free 容器、SIMD 或自定义 allocator。
- Windows 结果只用于开发回归；生产目标仍须在约定 Linux 基线上资格验证。

## Done when

- 有可重复命令、原始分布和环境说明，不只报告循环平均值。
- 正确性断言在基准过程中持续开启。
- 若未达到目标，票据记录可归因瓶颈和下一项最小修正，而不是降低性能合同。

## Activity

- 2026-07-30：已认领；开始测量现有 `TradingShard` 实际事件处理、日志 enqueue 与最低遥测路径。
- 2026-07-30：完成三轮百万样本 Windows 开发基线、一次原始直方图留存和持续正确性检查；票据解决。

## Answer

[`src/main.zig`](../../../src/main.zig) 的同一产品可执行程序新增 `--benchmark` 与
`--benchmark-raw` 入口。每个样本仍通过既有
`applyLive -> TradingShard.handle -> CRC32C journal append`，没有基准专用核心分支；
热路径观测使用固定容量本地直方图及计数器，测量中没有动态分配、阻塞锁或网络调用。

### 可重复命令

```powershell
zig test src\main.zig -O ReleaseSafe
zig build-exe src\main.zig -O ReleaseFast '-femit-bin=.scratch/single-shard-benchmark.exe'
1..3 | ForEach-Object { .\.scratch\single-shard-benchmark.exe --benchmark }
.\.scratch\single-shard-benchmark.exe --benchmark-raw
```

### 开发环境

- Windows 10 Enterprise LTSC `10.0.17763`，Intel Core i5-4200U
  `2C/4T @ 1.60 GHz`。
- Zig `0.17.0-dev.315+5b647b792`，`ReleaseFast`。
- 每个场景至少 1,000,000 样本，先执行 50,000 样本预热。
- 单调时钟；0–20 ms 使用 500 ns 固定桶，20 ms–1.02 s 使用 1 ms 尾桶。
- 原始桶保存在
  [`benchmarks/06-single-shard-windows-raw.txt`](../benchmarks/06-single-shard-windows-raw.txt)，
  SHA-256 `F88C70FEE196D017AC1190850655371CA091315943C6A44EE5844A30F3CC5B18`。

### 三轮结果

单位：延迟为 ns，吞吐为 events/s。

| 场景/轮次 | P50 | P99 | P99.9 | Max | 吞吐 | 队列最高水位 |
|---|---:|---:|---:|---:|---:|---:|
| Steady 1 | 500 | 1,000 | 2,500 | 2,067,200 | 1,960,139 | 1/128 |
| Steady 2 | 500 | 1,000 | 10,000 | 31,847,000 | 1,663,238 | 1/128 |
| Steady 3 | 500 | 1,000 | 4,000 | 2,320,100 | 1,977,840 | 1/128 |
| MarketBurst 1 | 15,000 | 36,500 | 77,500 | 618,700 | 1,957,510 | 64/128 |
| MarketBurst 2 | 15,500 | 39,500 | 110,000 | 1,904,500 | 1,890,731 | 64/128 |
| MarketBurst 3 | 13,500 | 34,000 | 95,000 | 738,100 | 2,210,880 | 64/128 |
| OrderBurst 1 | 16,000 | 36,500 | 143,500 | 4,621,700 | 223,832 | 8/16 |
| OrderBurst 2 | 16,000 | 34,500 | 95,000 | 2,804,400 | 231,125 | 8/16 |
| OrderBurst 3 | 16,000 | 34,000 | 88,500 | 728,200 | 233,394 | 8/16 |
| Recovery 1 | 1,500 | 3,000 | 13,000 | 495,800 | 776,987 | 3/6 |
| Recovery 2 | 1,500 | 2,500 | 12,500 | 428,900 | 781,829 | 3/6 |
| Recovery 3 | 1,500 | 2,500 | 12,500 | 562,800 | 795,596 | 3/6 |

全部运行均为 `overflow=0`、`correctness_failures=0`，队列未满。基准过程持续验证
市场序号/健康状态、可发送命令、定点风险预留和日志事实数。

### 结论

- 稳态 `CoreDecisionLatency` 三轮 P99 均为 `1 us`，低于 `10 us` 合同；
  单分片持续吞吐最低 `1.66M events/s`，高于四分片平均目标所需的
  `500k events/s/shard`。
- `OrderBurst` 三轮 P99 均低于 `50 us`，但第一轮 P99.9 为 `143.5 us`，
  未连续满足 `100 us`；`MarketBurst` 把 64 个事件的实际队列等待纳入分布，
  因而不能冒充无排队的 `CoreDecisionLatency`。
- Windows 出现最高 `31.847 ms` 的稳态调度停顿；同一代码的订单 P99.9 在另两轮为
  `95/88.5 us`。现有证据不支持用对象池、lock-free、SIMD、自定义 allocator
  或改动业务算法来处理 OS 调度长尾。
- 本票只建立开发回归基线，不授予生产性能资格。下一项最小修正不是修改交易核心，
  而是在约定 Linux 独占核心、固定 CPU、真实生产日志 enqueue 和独立计划负载生成器上
  重跑；届时若剖析证明必要业务工作超标，再改对应热路径。
