来源：`.scratch/trading-core-system-closure/map.md`（wayfinder 地图）

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

## 进度（同步时点）

01–07 已完成并记录于地图 Decisions；当前 frontier 为 08「闭合四分片与共享账户协调」；09、10 待做（09 被 08 阻塞）。
