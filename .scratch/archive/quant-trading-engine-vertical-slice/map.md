# 实现确定性交易引擎最小纵向闭环

Label: wayfinder:map
Status: resolved

## Notes

- 本地图经用户明确授权将执行工作纳入路线；`implementation` 票可直接修改产品原型代码，但每次仍只认领并完成一张 frontier。
- 实现遵循 Ponytail：复用现有定点算法与 Zig 标准库，只构建当前票据要求的最小纵向路径。

## Destination

交付一个可执行的 Zig 交易引擎产品原型：一个 TradingShard 顺序处理确定性行情、TimerEvent、原生示例策略、OrderIntent、本地风险、OrderCommand、模拟 Venue 回报、订单/仓位/账本/PnL 投影和分片决策日志；同一输入日志重放后必须得到相同的事实序列与最终状态摘要。

首个闭环使用一个模拟 Venue、一个 Gate.io 形状的 `BTC_USDT` USDT 线性永续品种、一个 VirtualPortfolio、一个 ExchangeAccount 和一个静态编译原生示例策略。它证明交易核心的业务链闭合，不连接真实交易所，也不证明策略盈利。

完成单分片正确性和端到端基准后，以同一 TradingShard 实现实例化四个分片，验证专用核心容量目标、行情定向扇出、过载隔离及 P99 是否发生不可接受退化。

## Acceptance traces

最终可执行原型至少能以固定输入运行并自动验证以下轨迹：

1. **Happy path**：L2 快照和连续增量使市场健康，TimerEvent 触发策略，OrderIntent 经定点风险准入形成 OrderCommand，模拟 Venue 依次返回接受、部分成交和完全成交事实，最终订单、PortfolioPosition、ExchangePosition、双层账本和 PnL 闭合。
2. **Market gap**：行情序号缺口使相关市场停止新增风险，重同步完成前策略不得产生可发送的增仓命令。
3. **Risk rejection**：额度、保证金或规范化失败形成稳定拒绝事实，模拟 Venue 不得观察到 OrderCommand。
4. **Ambiguous execution**：发送结果不明确进入 Unknown，风险占用保持；对账得到确定证据后才恢复为终态或允许重试。
5. **Idempotency**：重复执行回报不重复改变订单、仓位、余额、费用或 PnL。
6. **Replay equivalence**：实时运行与从决策日志重放产生相同的有序事实、最终状态摘要和账本闭合结果。

## Implementation rules

- 只建立一个产品原型可执行程序；不建立微服务、插件系统或通用消息总线。
- TradingShard 是深模块，其外部 interface 只接收版本化输入事件并产出不可变事实/命令；测试也只穿过这条 seam。
- 首个纵向闭环只运行一个 TradingShard。Venue 行情接入、规范化、Execution Gateway 和全局额度仍作为共享外围职责，不复制进分片。
- 权威金额、价格、数量、费率和 PnL 全部使用定点整数；`f64` 不参与状态演进或验收摘要。
- 同一核心状态转换用于实时驱动和日志重放；模拟 Venue 是外围驱动，不在核心中增加“回测专用”分支。
- 现有事件编码、定点保证金和 Python Host 均为 throwaway prototype；复用其已确认契约和最小算法，不复制其演示结构。
- 每张实施票必须留下一个可运行检查；性能票以前不得以微基准结果宣称端到端目标达标。

## Route

- [冻结纵向闭环验收轨迹与状态摘要](issues/01-freeze-acceptance-traces.md)
- [建立单进程内存态 walking skeleton](issues/02-build-in-memory-walking-skeleton.md)
- [闭合订单、双层仓位、账本与定点风险](issues/03-close-authoritative-projections.md)
- [接入稳定日志并证明重放等价](issues/04-journal-and-replay-equivalence.md)
- [实现缺口、拒绝、Unknown 与幂等失败轨迹](issues/05-failure-traces-and-reconciliation.md)
- [测量并收敛单分片端到端性能](issues/06-single-shard-performance.md)
- [以同一实现验证四分片容量与隔离](issues/07-four-shard-qualification.md)
- [形成可复现演示并关闭产品原型阶段](issues/08-close-vertical-slice.md)

## Decisions so far

- [纵向闭环验收轨迹与状态摘要](issues/01-freeze-acceptance-traces.md) 已冻结：五条独立 fixture 共用 11-event Genesis，固定身份、定点数值、事件顺序、时间公式、双层经济终态、风险占用、幂等断言和 StateDigestV1 契约。
- [建立单进程内存态 walking skeleton](issues/02-build-in-memory-walking-skeleton.md) 已完成：单文件 Zig 产品入口让 Genesis、行情、策略、风险、OrderCommand 和 SimVenue 执行事实通过同一个 TradingShard seam，并以 ReleaseSafe 双运行自检证明 26-event 骨架确定。
- [闭合订单、双层仓位、账本与定点风险](issues/03-close-authoritative-projections.md) 已完成：31-event happy path 以纯定点状态闭合双层仓位、现金、借贷 posting、手续费、移动加权成本、PnL 与风险额度，并锁定 StateDigestV1。
- [接入稳定日志并证明重放等价](issues/04-journal-and-replay-equivalence.md) 已完成：31-record 稳定 CRC32C 日志可封存、扫描和完整重放，实时/重放摘要一致，截断尾部安全恢复，损坏、缺口与未知 schema 失败关闭。
- [实现缺口、拒绝、Unknown 与幂等失败轨迹](issues/05-failure-traces-and-reconciliation.md) 已完成：行情缺口、额度拒绝、Unknown 对账和重复回报四条轨迹全部复用同一核心/日志/重放路径，锁定摘要并验证重复经济事实 no-op、冲突身份失败关闭。
- [测量并收敛单分片端到端性能](issues/06-single-shard-performance.md) 已完成：同核百万样本基准覆盖稳态、行情突发、订单突发和异常恢复；Windows 开发基线的稳态核心 P99 为 1 μs、单分片最低吞吐 1.66M events/s，订单 P99 达标但调度长尾仍须 Linux 固定核心资格化。
- [以同一实现验证四分片容量与隔离](issues/07-four-shard-qualification.md) 已完成：同一 TradingShard 的四实例重放、定向扇出和局部过载隔离通过；2C/4T Windows 节点虽接近 2M events/s，但调度追赶使 P99 达 0.961–2.348 ms，生产资格须在至少 5 个可独占物理核的 Linux 基线上重跑。
- [形成可复现演示并关闭产品原型阶段](issues/08-close-vertical-slice.md) 已完成：SystemOwner 确认闭环，根目录 README 固化复现入口与证据边界，并选择 Python StrategyHost 产品化接入作为下一能力波次。

## Frontier

无；本地图已完成。下一阶段见
[产品化接入 Python StrategyHost](../python-strategy-host-productization/map.md)。

## Reused evidence

- [已完成的业务逻辑规格地图](../quant-trading-system/map.md)
- [事件编码与日志吞吐原型](../quant-trading-system/prototypes/event-codec/README.md)
- [定点保证金与强平求解原型](../quant-trading-system/prototypes/fixed-point-margin-engine/README.md)
- [Python Strategy Host 原型](../quant-trading-system/prototypes/python-strategy-host/README.md)
- [动态目标架构图](../../docs/trading-engine-architecture.html)

## Out of scope

- 真实 OKX、Binance、Gate.io 或 Bitget 网络连接、API 密钥和真实下单。
- Python StrategyHost 的产品化接入；它在原生单分片闭环稳定后的下一能力波次处理。
- 单活热备、fencing、生产部署、CPU/NUMA 精调、io_uring、生产 UI 和密钥管理实现。
- 研究数据平台、参数扫描、可视化回测报告和控制面技术选型。
- 多资产通用框架、现货、期权、组合保证金、跨分片多腿原子决策和 Smart Order Router。
- 盈利策略、Alpha 研究或收益承诺。
