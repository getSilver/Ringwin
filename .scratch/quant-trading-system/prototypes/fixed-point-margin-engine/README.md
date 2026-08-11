# 定点保证金与强平求解原型

> Throwaway prototype：验证业务算法，不是 Venue 官方公式或生产风险引擎。

## 问题

在完全不使用 `f64` 的权威计算中，最小模型能否同时表达：

- 初始/维持保证金与档位跨越；
- 买入优先、卖出优先的挂单最坏最终敞口；
- Portfolio 与 Exchange 两层 `MarginBuffer`；
- 按价格 tick 搜索的 `LiquidationDistance`；
- 独立的 `PortfolioReduceOnly` / `VenueReduceOnly`；
- 强制执行按事前同向贡献仓位、最大余数法精确分配？

## 一条命令

```powershell
zig run -O ReleaseSafe .scratch/quant-trading-system/prototypes/fixed-point-margin-engine/main.zig
```

最小自检与本机计算核微基准：

```powershell
zig run -O ReleaseSafe .scratch/quant-trading-system/prototypes/fixed-point-margin-engine/main.zig -- --check
zig run -O ReleaseFast .scratch/quant-trading-system/prototypes/fixed-point-margin-engine/main.zig -- --bench 1000000
```

## 样本边界

样本采用 2026-07-29 Gate.io `BTC_USDT` 公共接口快照的字段形状与前三档数值：

| 上限 USDT | IMR | MMR | deduction USDT |
| ---: | ---: | ---: | ---: |
| 500,000 | 0.005 | 0.003 | 0 |
| 1,000,000 | 0.006666 | 0.0035 | 250 |
| 1,500,000 | 0.008 | 0.004 | 750 |

合约乘数为 `0.0001 BTC/contract`，价格 tick 为 `0.1 USDT`，普通 taker fee 样本为 `0.00075`。交互场景明确配置账户杠杆为 `50x`，有效 IMR 取 `max(1 / account leverage, tier initial_rate)`，不再把风险档位允许的最大杠杆误当成账户实际杠杆。

金额保存为微 USDT，费率保存为 ppm，乘法使用 `i128` 中间值；保证金和费用朝增加要求方向取整，负 UPL 向负无穷取整。界面显示完整 6 位金额精度。

`current` 行只表示当前持仓的 MM、权益和清算缓冲；`opening` 行同时显示最坏 IM 档位、所有买卖挂单费用之和、保证金预留余量，以及最坏单侧成交后的预测数量和 `MarginBuffer`。同一挂单同时进入 Portfolio 和 Exchange 两层预测。

强制执行示例对 Quantity、RealizedPnL、Fee 和 Penalty 分别使用事前同向仓位权重及确定性最大余数法，四个分量都必须精确闭合。

档位上界暂按“包含上界”处理。该边界、Venue 内部舍入顺序和强平费用必须经 testnet 差分后才能标记为 `TestnetQualified`。Venue 返回的强平价始终是并列的 `ReferenceOnly` 值，不能覆盖本地结果。

本机微基准只测 `assess` 计算核，不含队列、事件解码、策略、风控链、日志、网关与网络，因此不能证明完整 `InternalOrderLatency` 达标。

## 2026-07-29 本机结果

Windows、Zig `0.17.0-dev.315+5b647b792`、`ReleaseFast`，修正后每轮 1,000,000 次完整 `assess`，七轮中位数为 `1,724 ns/op`（约 `580K assessments/s`），观测范围为 `1,141..2,151 ns/op`。

`ReleaseSafe` 自检覆盖档位分离、账户杠杆、全部挂单手续费、最坏成交后 buffer、Reduce-only 方向约束和强制执行经济金额闭合；两个 `.zig` 文件中未出现浮点类型或浮点转换。

结论是：纯定点业务模型可以覆盖本票列出的核心语义，单次计算核与 `InternalOrderLatency P99 <= 50 μs` 预算相比有足够数量级余量。但本机循环平均值没有 P99/P99.9，也未覆盖完整订单路径，因此正式延迟资格仍须在生产等价 Linux 全链路负载中验证。
