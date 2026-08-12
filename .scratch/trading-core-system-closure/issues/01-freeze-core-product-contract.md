# 冻结交易核心产品闭环与权威所有权

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何把现有单 fixture TradingShard、Python StrategyHost seam、SimulatedVenue 与 OKX Demo 事实映射为一套不依赖具体 Adapter 的核心产品验收矩阵，明确每类 Order、风险占用、经济投影、操作授权、恢复状态和跨分片账户事实的唯一所有者、输入、输出、失败关闭结果及稳定摘要，从而冻结后续实现的 interface 与完成标准？

## Answer

### Core interface

后续实现只深化一套 `TradingShard`，不保留“Gate.io fixture 核心”和“OKX spot projection 核心”两套权威状态。其外部 interface 冻结为三类行为：

1. `apply(CanonicalEvent) -> bounded facts/OrderCommand`：顺序应用版本化外部事实、控制事实、策略事实和内部决定，返回本次产生的有界不可变事实及零或多个 OrderCommand。
2. `snapshot(shard barrier) -> AuthoritativeTradingState snapshot`：只在已完整应用的 ShardSequence 上生成稳定、版本化、带摘要的权威快照。
3. `restore(snapshot, stable journal) -> readiness`：验证快照后从下一 ShardSequence 语义重放；只有恢复、Venue 对账和全部 SafetyGate 闭合后才能重新获得新增风险权限。

`VenueAdapter` 的 `start/trySend/tryDrain/stop`、StrategyHost Gateway 和稳定 journal 保持独立外围 seam；它们不能直接修改 TradingShard。SimulatedVenue 与 OKX 继续只把 `OrderDispatchResult` 和 CanonicalEvent 送回 `apply`。历史重放构造的核心不持有可发送的 VenueAdapter，因此类型和运行路径上都不能重发副作用。

当前 `src/main.zig` 的单 Instrument/单 Order/fixed Genesis struct 是待深化的实现，不是要兼容的产品 interface；`okx_spot_projection.zig` 已验证的现货原币经济规则必须回收到同一 TradingShard 经济模块，随后不再独立拥有权威状态。

### Authoritative ownership

| 状态或决定 | 唯一所有者 | 合法输入 | 可观察输出 | 失败关闭结果 |
|---|---|---|---|---|
| Strategy authorization 与 Intent identity | TradingShard | HostActivated、原生/Python OrderIntent、session/cursor/config facts | StrategyIntentRejected 或进入规范化的 OrderIntent | 旧 session、stale、重复冲突或未授权不进入风险 |
| InstrumentRules 与 MarginRules activation | TradingShard | 经验证的 ConfigEvent | 当前版本及依赖该版本的 RiskDecision/OrderCommand | 未激活、过期或不适用规则关闭目标 Instrument 新增风险 |
| RiskDecision 与 reservation | TradingShard | 规范 OrderIntent、市场/账户/仓位/额度事实 | RiskAccepted/Rejected、PortfolioMarginReservation、OrderCommand | 任一层级未知或超限不产生 OrderCommand；Unknown 保留占用 |
| Order 与 OrderState | TradingShard | OrderCommand、OrderDispatchResult、ExecutionReport、OrderReconciliationResult | 规范订单事实和后续命令 | Adapter response 不能直接改终态；乱序不可使状态回退 |
| Portfolio economic state | TradingShard | 已归属 Fill、FundingSettlement、ForcedExecutionAllocation、不可变账本事实 | PortfolioBalance/Position、cost、fee、PnL、reservation | 重复为 no-op，身份冲突锁存 reconciliation break |
| Exchange economic state | TradingShard | Venue balance/position/margin snapshots、Fill、VenueForcedExecution | ExchangeBalance/Position/Margin 投影与 reconciliation facts | snapshot 只核对，不覆盖 Portfolio ledger 或猜测归属 |
| OperationalMode 与 SafetyGate | TradingShard | ControlCommand、市场/凭证/租约/对账/恢复事实 | Ready/Trading/Draining/Stopped、允许的撤单或 Reduce-only 命令 | gate 解除不自动清除 LatchedSafetyGate 或恢复授权 |
| ShardSequence、stable journal、snapshot digest | TradingShard/journal module | 每个已接受 CanonicalEvent 与内部事实 | 连续日志、snapshot、CanonicalStateDigest | 序号缺口、CRC/schema/digest 冲突停止恢复与新增风险 |
| ExchangeAccount 聚合限制 | 共享账户协调器 | 各 shard 的有版本占用/仓位摘要及 Venue account facts | RiskLease、账户 reconciliation 与收紧的 SafetyGate | stale/缺失 shard 或账户净额不确定时不分配新增额度 |

共享账户协调器只拥有跨 DecisionDomain 的额度和账户核对，不拥有任何 shard 内 Order、PortfolioPosition 或账本。TradingShard 只能消费显式 RiskLease，不能使用 `AccountNettingBenefit` 增加购买力。

### Frozen acceptance matrix

| 轨迹 | 最小情景 | 必须证明的核心结果 | 后续票 |
|---|---|---|---|
| Genesis and authority | 多 Instrument rules、账户配置、Portfolio、策略、lease 按明确顺序激活 | 缺任一前置事实均不进入 Trading；相同 Genesis 重放摘要一致 | 02 |
| Multi-order OMS | SPOT 与 SWAP 各有多个 place/amend/cancel，含 batch partial 与 CancelConfirmCreate | 身份、revision、predecessor、终态和 reservation 独立闭合 | 03 |
| Layered risk | SPOT 买卖现金、SWAP 逐仓增减仓、费用缓冲、Unknown | 五层限制取最严格；占用守恒且只由权威事实释放 | 04 |
| Economic closure | 部分成交、多次成交、费用/返佣、资金费、强制执行及账户 snapshot | Portfolio/Exchange 双层数量、原币余额、margin、cost、PnL 和借贷 posting 闭合 | 05 |
| Operator lifecycle | enable、pause、cancel open、keep positions、de-risk/flatten、kill、resume | mode 与 gate 正交；只允许规定的新增风险/撤单/Reduce-only；锁存原因需明确授权解除 | 06 |
| Restart recovery | 活动 Order、Unknown、持仓和策略 checkpoint 下快照/截断/重启 | 快照加日志恢复相同状态；Venue 对账前不开放新增风险；无副作用重放 | 07 |
| Cutover | 有/无活动订单的策略或核心版本切换 | CutoverDrain、barrier、VersionActivationEvent 顺序固定，经济事实不回滚 | 07 |
| Four shards/account | 四 shard 共享一个 ExchangeAccount，一 shard gap/overload/reconciliation break | 局部状态单写者；账户 gate 可向下收紧；其他 shard 顺序不变且不消费净额收益 | 08 |
| Strategy seams | 原生与四个 Python Host 产生同语义 intent | 同一规范化、风险、OMS、日志和拒绝原因，无 Python 权威旁路 | 09 |
| Venue seams | 同一 OrderCommand 先经 SimulatedVenue，再用显式 OKX Demo 事实验证 | 核心结果只依赖规范事实；Adapter 字段/时序不进入摘要；replay 不发送 | 09 |
| Fault matrix | gap、stale、auth loss、backpressure、Unknown、duplicate/conflict、snapshot corruption、cleanup failure | 每个失败对应明确 gate/order/reservation 状态和恢复权限，无猜测式重试 | 09 |

每条轨迹必须验证三种结果：有序稳定事实、最终 AuthoritativeTradingState/CanonicalStateDigest、全部经济与风险守恒断言。真实 Demo 的订单/成交/时间身份会导致跨运行 digest 不同，因此只要求单次 live 与其 semantic replay 等价；离线 fixture 必须固定完整 digest 字面值。

### Bounded product scope

本波产品 Instrument fixture 固定为 BTC-USDT SPOT 与 BTC-USDT-SWAP isolated/net；多 Instrument 指核心能同时拥有二者，不表示开放动态任意 symbol。订单种类继承已冻结能力，不增加算法单、SOR 或跨分片多腿原子性。容量使用编译期上限并在满时产生稳定 backpressure/拒绝，具体上限由第 02/03 票基于当前测试规模选择，不暴露可无限增长容器。

完成标准是第 09 票的一条自动入口能从干净 Genesis 运行全部矩阵、执行进程级 restart recovery，并让 SimulatedVenue 与显式 OKX Demo 穿过同一核心 interface；单元测试、Adapter 验收或现有固定 happy path 均不能单独关闭本地图。
