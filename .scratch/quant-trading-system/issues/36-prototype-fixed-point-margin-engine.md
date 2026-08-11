# 原型验证定点保证金与强平求解

Type: prototype
Status: resolved
Blocked by: 29, 35
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

使用真实 Venue 风险档位与事件 schema 的最小定点实现，能否在无 f64 的前提下正确处理初始/维持保证金、挂单最坏场景、档位跨越、双层 MarginBuffer、LiquidationDistance、双 Reduce-only 和强制执行分配，并在正式热路径负载下满足 InternalOrderLatency？

## Answer

可以使用纯定点整数实现本票所需的保证金业务语义，而且计算核开销相对于 `InternalOrderLatency P99 <= 50 μs` 合同具有数量级余量；但本机计算核平均耗时不能证明正式端到端延迟达标。原型、运行方法、样本和实测结果见[定点保证金与强平求解原型](../prototypes/fixed-point-margin-engine/README.md)。

### 原型边界与数值表示

- 原型使用 Zig `0.17.0-dev.315+5b647b792`，纯逻辑位于 [`model.zig`](../prototypes/fixed-point-margin-engine/model.zig)，交互终端位于 [`main.zig`](../prototypes/fixed-point-margin-engine/main.zig)。
- Money 和 Price 使用微 USDT 的 `i64`，Quantity 使用整数合约张数，Rate 使用 ppm；乘除使用 `i128` 中间值。
- 保证金、手续费及其他风险要求向增加要求的方向取整，负 UPL 向负无穷取整。源码扫描确认没有 `f16/f32/f64` 或浮点转换。
- 原型使用 2026-07-29 Gate.io `BTC_USDT` 公共接口快照的前三档、`0.0001 BTC/contract` 合约乘数、`0.1 USDT` price tick 和 `0.00075` 普通 taker fee。
- 交互场景明确配置账户杠杆为 `50x`。有效 IMR 为 `max(1 / account leverage, tier initial_rate)`，不能把档位允许的最大杠杆当作账户实际杠杆。
- Gate 档位上界暂按包含上界处理。档位边界、实际逐仓杠杆字段、平均 MMR、强平费用及中间舍入仍以 testnet 差分结果为准，原型不宣称复刻 Venue 私有风险引擎。

### 初始保证金、维持保证金与挂单

- 当前持仓使用标记价格选择 MM 档位并计算 CurrentMarginBuffer；最坏挂单最终敞口独立选择 IM 档位。界面分别显示 `current_tier` 和 `IM_tier`，避免把两者混为一档。
- 对当前仓位 `q`、未完成买入量 `B` 和卖出量 `S`，分别计算买侧 `q+B` 与卖侧 `q-S`，使用各自受保护的最坏成交价，不让相反挂单静态抵消。
- IM 使用两侧最终敞口中的更高要求；费用占用为全部可能成交的买侧费用与卖侧费用之和，不取两者最大值。
- `reservation_required = worst_initial_margin + all_order_fees`；`reservation_surplus = occupied_margin - reservation_required`，负值表示该层不能为订单取得资格。
- 对买侧和卖侧分别模拟成交后的新仓位、成交相对 mark 的损益、实际成交手续费、MM 档位、预计平仓费和 MarginBuffer，并取更差的 `projected_margin_buffer`。
- 有效 PortfolioReduceOnly 必须与当前 PortfolioPosition 方向相反、数量不超过可减仓数量且不得穿过零点；它不增加持仓 IM，但仍预留成交手续费。方向错误或可能反向开仓的请求明确拒绝。

### 双层安全判断

- 同一个候选订单同时进入 VirtualPortfolio 和 ExchangeAccount 两层预测。
- Portfolio 层使用 PortfolioPosition 与 PortfolioMarginReservation；Exchange 层使用净 ExchangePosition 与 ExchangeMarginBucket。
- 当前安全判断和订单成交后预测分别选取 buffer 更差的一层，输出 `current_governing` 与 `projected_governing`。
- 原型样本中两层仓位相同但 Exchange 保证金少 2,000 USDT，因此当前和预测结果都由 Exchange 层约束；这证明组合充足不能掩盖真实账户风险。
- 多投资组合聚合、AccountNettingBenefit 和最坏退出场景仍遵循[定义保证金归属、强平距离与抵押品边界](28-margin-liquidation-and-collateral.md)，本原型只用一个投资组合展示双层计算接口。

### 强平阈值与距离

- 强平求解不使用跨 Venue 的统一闭式公式，而是复用同一 MM、扣减额和费用函数，沿不利价格方向按 tick 二分搜索首次使 MarginBuffer 不大于零的价格。
- 多仓向下搜索，空仓向上搜索；零仓位返回无 LiquidationDistance。
- 样本 Exchange 层在 mark `50,000.0` 时得到本地阈值 `47,678.7`、距离 `23,213 ticks / 465 bps`；在 mark `49,900.0` 时阈值不变，距离变为 `22,213 ticks / 446 bps`。
- 本地阈值是内部权威风险结果；Venue 返回的 `liqPx/liquidationPrice` 仍作为 ReferenceOnly 并列对账，超过版本化容差时失败关闭。

### 双 Reduce-only 与强制执行分配

- `PortfolioReduceOnly` 与 `VenueReduceOnly` 独立计算。样本卖出 8 张使组合 `+10 -> +2`，但使账户 `-5 -> -13`，因此前者为 true、后者为 false。
- VenueForcedExecution 只分配给强制执行前与真实仓位同方向的 PortfolioPosition，权重为其绝对数量。
- Quantity、RealizedPnL、Fee 和 Penalty 分别使用确定性最大余数法；余数相同按稳定 Portfolio ID 排序。
- `3:2:1` 的贡献仓位分配强制减仓 4 张得到 `2:1:1`。原型同时验证 `-120.000001` PnL、`-3.000001` Fee 和 `-1.000001` Penalty 的逐分量精确闭合。
- 无贡献仓位、强制数量超过事前同向仓位或无法闭合时明确失败；正式领域流程将无法唯一归属的部分记入 SuspenseAccount 并形成 ReconciliationBreak。

### 事件与确定性边界

- 原型的 State、Assessment、ForcedEconomics 和 Allocation 是纯输入/输出值，不读取时钟、网络、文件或全局可变状态；相同输入得到相同结果，可供回测、仿真和实盘同核调用。
- 这些值分别对应 RiskDecision/RiskReservationChanged 计算摘要、ExchangeMarginSnapshot、VenueForcedExecution 和 ForcedExecutionAllocation 的业务字段。
- 原型不重复实现稳定日志编码；正式内存事件与版本化持久表示继续遵循[定义完整事件分类、字段与兼容性契约](29-event-taxonomy-and-schema-compatibility.md)。

### 验证与性能结论

- 内置 `--check` 覆盖档位上界与跨档、账户杠杆、买卖手续费求和、挂单最坏方向、成交后 buffer、无效/有效 Reduce-only、零仓位强平和四类强制执行金额闭合。
- 用户通过交互命令验证 mark 上下变化、增加买卖挂单、双 Reduce-only 分歧及强制执行分配，确认展示结果符合预期。
- 修正后的 Windows `ReleaseFast` 七轮、每轮 1,000,000 次完整 `assess`，中位数为 `1,724 ns/op`，约 `580K assessments/s`，观测范围为 `1,141..2,151 ns/op`。
- 该结果只测纯计算核平均耗时，没有 P99/P99.9，也不包含解析、订单簿、跨线程队列、策略、OMS、事件日志、网关序列化和正式观测开销。
- 因此本票结论是“业务模型及性能量级可行”。正式 `InternalOrderLatency P99 <= 50 μs` 仍必须在生产等价 Linux、完整订单路径和规定资格负载下验收；关闭保证金逻辑的结果无效。

## Comments

- 2026-07-29：完成 Gate.io 样本纯定点原型、回归自检和本机微基准。
- 2026-07-29：根据用户体验修正账户杠杆、IM/MM 档位歧义、金额显示精度、全部挂单费用、双层成交后预测、Reduce-only 方向验证、强制执行经济金额闭合及空行重复渲染。
- 2026-07-29：用户复核交互输出并确认解决。
