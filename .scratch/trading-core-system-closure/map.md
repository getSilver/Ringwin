# 完成交易核心系统闭环

Label: wayfinder:map
Status: open

## Destination

把现有确定性 TradingShard 纵向样例、Python StrategyHost 产品 seam 和 OKX Demo 事实链收敛为一个交易核心产品闭环：同一核心 interface 对原生及 Python OrderIntent 执行多 Instrument 规范化、分层定点风险、完整 OMS、双层仓位/余额/保证金/账本投影、操作生命周期、安全栅栏、日志快照与恢复，并在单分片及四分片下保持明确的账户协调与权威所有权。

现有 OKX Adapter 和 SimulatedVenue 只作为 `VenueAdapter` seam 的两个验证 Adapter；本地图不增加 Binance、Gate.io、Bitget，不扩展 OKX 协议能力，也不建设通用 Venue 插件框架。

## Definition of done

- `TradingShard` 是核心深模块；原生策略、Python StrategyHost、SimulatedVenue 和 OKX 均只能通过已冻结 interface 交换版本化输入、OrderCommand、OrderDispatchResult 与 CanonicalEvent。
- SPOT 与 isolated/net USDT 永续在同一领域模型下覆盖多 Instrument、多 Order、原地 amend/cancel、授权 CancelConfirmCreate、逐项 TransportBatch 与 IntentGroup 部分执行政策。
- 风险在 OrderCommand 前闭合 StrategyInstance、VirtualPortfolio、DecisionDomain、ExchangeAccount 和全局限制；现金、保证金、费用缓冲、Unknown 及 open-order reservation 只由权威事实释放。
- Portfolio/Exchange 双层余额、仓位、margin、费用、资金费、强制执行、OpenCost、Realized/UnrealizedPnL 和账本逐原子闭合；对账差异不得覆盖本地账本。
- OperationalMode、TradingAuthorization、KillSwitch、TradingPause、CancelOpenOrders、DeRisk/Flatten 与 SafetyGate 形成可重放状态机；危险解除不能越权恢复交易。
- 稳定日志、快照、截断恢复、Unknown 对账、策略 checkpoint 追赶和版本切换在明确 shard barrier 上恢复相同 AuthoritativeTradingState 与 CanonicalStateDigest。
- 四个 TradingShard 保持单写者与局部故障隔离；共享 Execution Gateway 和 ExchangeAccount 协调不复制 Venue 接入，也不允许跨分片消费账户净额收益。
- 一条失败即停的自动入口覆盖离线成功/失败/重启轨迹、Python seam、SimulatedVenue 和显式启用的 OKX Demo 事实；历史重放永不重发副作用。

## Rules

- 每次只完成一张 frontier；先深化现有模块，不创建平行第二套核心。
- 权威状态演进只使用定点整数和不可变事实；`f64`、当前墙钟和随机身份不得进入结果。
- 不以 Adapter、脚本或测试程序拥有订单、风险、仓位、账本或恢复权限。
- 不为生产部署、控制面 UI、研究数据平台、SOR、期权、组合保证金或尚未存在的 Venue 预建抽象。
- Windows 可完成功能回归；Linux 专用核心性能、io_uring、CPU/NUMA 与生产网络资格独立处理，不阻塞业务闭环。

## Route

- [冻结交易核心产品闭环与权威所有权](issues/01-freeze-core-product-contract.md)
- [把 fixture 形状的 TradingShard 深化为产品核心模块](issues/02-deepen-trading-shard-module.md)
- [闭合多 Instrument SPOT 与永续 OMS 生命周期](issues/03-close-multi-instrument-oms.md)
- [闭合分层风险、现金与逐仓保证金占用](issues/04-close-layered-risk-and-margin.md)
- [闭合双层经济投影、账本与账户对账](issues/05-close-economic-projections.md)
- [实现操作生命周期、授权与安全栅栏](issues/06-operational-lifecycle-and-safety.md)
- [实现核心快照、重启恢复与版本屏障](issues/07-snapshot-recovery-and-cutover.md)
- [闭合四分片与共享账户协调](issues/08-shards-and-account-coordination.md)
- [形成核心成功/故障整波自动验收](issues/09-core-wave-acceptance.md)
- [形成可复现证据并关闭交易核心波次](issues/10-close-trading-core-wave.md)

## Frontier

[实现核心快照、重启恢复与版本屏障](issues/07-snapshot-recovery-and-cutover.md)

## Decisions so far

- [冻结交易核心产品闭环与权威所有权](issues/01-freeze-core-product-contract.md) — 后续只深化一套 TradingShard；冻结 `apply/snapshot/restore` 核心 interface、九类权威所有权和十一条成功/故障矩阵。Adapter、StrategyHost、journal 与账户协调器保持外围 seam，OKX spot projection 的经济规则必须回收到同一核心，历史重放不得持有发送能力。
- [把 fixture 形状的 TradingShard 深化为产品核心模块](issues/02-deepen-trading-shard-module.md) — TradingShard 已成为唯一产品模块；显式、版本化 Genesis 与有界 `apply(CanonicalEvent)` 统一原生/Python 意图和 SimulatedVenue/OKX 执行结果，ReplayTradingShard 不持有发送能力，当前 CanonicalStateDigest 覆盖产品配置。
- [闭合多 Instrument SPOT 与永续 OMS 生命周期](issues/03-close-multi-instrument-oms.md) — 同一 TradingShard 以固定容量领域 OMS 闭合 SPOT/SWAP 多订单、原地 amend/cancel、IntentGroup 部分政策、逐项 batch、Unknown、授权 CancelConfirmCreate、reservation 生命周期与终态语义幂等；Venue 字段和调度仍停留在 Adapter seam。
- [闭合分层风险、现金与逐仓保证金占用](issues/04-close-layered-risk-and-margin.md) — TradingShard 在 OrderCommand 前以纯定点核计算 SPOT 现金、isolated/net USDT SWAP 保证金与费用，强制 StrategyInstance/VirtualPortfolio/DecisionDomain/ExchangeAccount/global 五层额度、双 Reduce-only 和两层 MarginSafetyGate；reservation 由核心拥有，Unknown 及未确认终态不会提前释放。
- [闭合双层经济投影、账本与账户对账](issues/05-close-economic-projections.md) — TradingShard 内部经济深模块从 OMS Order 取得 Fill 归属，以纯定点投影双层余额、仓位、OpenCost、margin、费用、返佣、资金费及 Realized/UnrealizedPnL；不可变账本逐事务借贷闭合，强制执行与 snapshot 差异进入 SuspenseAccount/ReconciliationBreak 而不覆盖本地状态。
- [实现操作生命周期、授权与安全栅栏](issues/06-operational-lifecycle-and-safety.md) — TradingShard 已以同一可重放状态机闭合稳定 ControlCommand 身份、OperationalMode/TradingAuthorization、独立 SafetyGate 聚合、Pause/CancelOpen/KeepPositions/DeRisk/Flatten/Kill/Resume 与 OMS 撤单副作用；危险原因、恢复资格、撤单结果及 EffectiveTradingAuthority 进入稳定摘要，解除 gate 不会越权重开交易。

## Reused evidence

- [交易核心业务逻辑规格](../quant-trading-system/map.md)
- [确定性交易引擎最小纵向闭环](../quant-trading-engine-vertical-slice/map.md)
- [Python StrategyHost 产品化接入](../python-strategy-host-productization/map.md)
- [OKX Demo Adapter 闭环证据](../okx-venue-adapter/map.md)
- [核心领域词汇与不变量](../../CONTEXT.md)

## Not yet specified

暂无；第 01 票已冻结本波 interface、所有权、验收矩阵和排除项。

## Out of scope

- 新 Venue Adapter 或扩展 OKX 协议/Instrument 范围。
- 生产账户、真实资金、生产密钥托管、部署、单活热备节点和外部 NodeFence 实现。
- Linux 专用核心性能、CPU affinity、NUMA、io_uring、硬件时间戳和真实网络延迟资格。
- 研究数据平台、策略盈利、控制面 UI、SOR、跨分片多腿原子交易、期权和组合保证金。
