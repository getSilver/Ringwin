# 设计生产级多策略低延迟加密量化交易系统

Label: wayfinder:map

## Destination

形成一份可以直接实现产品原型的核心业务逻辑规格：面向中心化加密交易所现货与永续合约，覆盖研究、回测、仿真和实盘的统一领域行为，支持原生策略与 Python 中低频策略，并明确交易、风控、账务、事件、恢复和交易所降级语义。

本地图只解决业务逻辑设计决策，不实施交易系统，也不详细规划生产硬件、部署和外围基础设施。

## Notes

- 领域：中心化加密交易所（CEX）的现货与永续合约。
- 每次会话先阅读本地图，只处理一个 frontier 决策票据；研究票据可以并行。
- 设计会话使用 `wayfinder`、`domain-modeling`、`codebase-design` 和 `ponytail`；按票据类型补充 `research`、`prototype` 或 `grilling`。
- 优先保证交易正确性、确定性和可恢复性；性能优化必须由端到端基准证明。
- 当前阶段只推进产品原型所需业务逻辑；已确认的生产性能、安全与高可用决策保留为未来约束，不继续细化外围实现。
- 原型实现先完成一个 TradingShard 的端到端纵向闭环，再以同一实现扩到四个固定核心做容量资格；共享行情接入、执行网关和全局额度不得按分片复制。
- 术语、状态与不变量写入后续领域模型；实现细节不得混入领域词汇表。
- 本地票据位于 [`issues/`](issues/)；`Status: open`、无阻塞且未认领的最小编号票据是 frontier。

## Decisions so far

- [确定系统终点、市场范围与性能合同](issues/01-system-scope-and-performance.md) — 目标是完整的 CEX 现货/永续多策略系统；核心 P99 不超过 10 μs，内部端到端 P99 不超过 50 μs。
- [选择单写者交易核心与交易决策域分片](issues/02-single-writer-trading-shards.md) — 共享外围只做一次接入、规范化、执行和全局额度分配；先完成单分片纵向闭环，再以同一实现扩到四个专用核心，分片之间不共享可变状态。
- [确定异步 I/O 与过载策略](issues/03-async-io-and-overload.md) — `io_uring` 是首选但须基准验证；使用有界通道、关键事件失败关闭和行情缺口重同步。
- [确定原生与 Python 策略执行模型](issues/04-strategy-execution-and-deployment.md) — 原生策略静态编译到 TradingShard；Python 中低频策略运行在独立进程。
- [确定双层账户与分层风控](issues/05-portfolios-accounts-and-risk.md) — 策略虚拟投资组合映射到交易所真实账户，使用全局额度租约、本地同步风控和执行安全栅栏。
- [确定统一执行、事件顺序与时间模型](issues/06-determinism-ordering-and-time.md) — 回测、仿真和实盘共用核心；使用分层序号、多时间戳和可重放 TimerEvent。
- [确定订单领域与恢复语义](issues/07-orders-and-recovery.md) — 使用意图、命令、订单和执行事实四层模型，通过唯一客户端订单号、Unknown 状态和对账恢复。
- [确定单活热备高可用模型](issues/08-high-availability.md) — 单活核心持有 fencing token，热备持续重放，原生策略按分片进行版本切换。
- [确定事件日志与快照模型](issues/09-journals-and-snapshots.md) — 保存原始接入日志和分片决策日志，并在序号屏障生成周期快照。
- [确定权威数值和事件表示](issues/10-numeric-and-event-representation.md) — 权威计算使用定点整数；内存事件与稳定、版本化的日志编码分离。
- [确定订单簿及行情健康模型](issues/11-market-data-and-order-books.md) — L2 是权威盘口，序号缺口触发不可交易状态和快照重同步。
- [确定三面架构与配置发布模型](issues/12-system-planes-and-configuration.md) — 交易面、研究数据面和控制面分离；代码蓝绿发布，参数通过版本化事件更新。
- [定义核心领域词汇、所有权与不变量](issues/13-define-domain-model.md) — 使用持久投资组合、唯一订单归属、不可变事实、派生投影、风险租约/占用和显式对账异常构成规范领域模型。
- [选择首批生产交易所](issues/14-choose-initial-venues.md) — 首批候选为 OKX、Binance、Gate.io、Bitget，按顺序适配；首版限定现货与 USDT 逐仓单向永续，并以专用账户、白名单和安全恢复门槛准入。
- [定义账本、PnL 与资金费用分配](issues/15-accounting-and-pnl.md) — 使用原币双层不可变账本、移动加权平均成本、成交归属费用与结算时点资金费分配，并以版本化估值和双路径核对形成可审计策略 PnL。
- [建立交易所适配器能力契约](issues/16-exchange-adapter-capabilities.md) — 能力按 Venue 和产品声明；客户端订单号不作为严格幂等键，私有 WS 不作为恢复日志，Unknown 订单及断线统一通过 REST 对账恢复。
- [定义回测和仿真保真等级](issues/17-backtest-simulation-fidelity.md) — 以生产同核的 L2 回放与实时影子仿真作为资格等级，采用保守排队、校准延迟、历史时点规则和严格 ComparableRun 契约。
- [定义研究数据保留与查询契约](issues/18-research-data-contract.md) — 将源归档、回放、研究派生和运行产物分层，以不可变数据集、point-in-time 血缘、明确保留期及并发查询合同支撑研究、审计与重算。
- [确定 Linux、Zig 与 io_uring 生产基线](issues/19-linux-zig-io-baseline.md) — Debian 13/Linux 6.12 LTS、固定到精确提交的 Zig 0.17.x、liburing 2.15；四核隔离、单 issuer io_uring 与 PHC 硬件时间戳通过节点准入测试固化。
- [定义密钥、安全边界与操作授权](issues/20-security-and-operator-authorization.md) — 单一 SystemOwner 通过 TOTP 会话管理生产，执行网关独占最小权限凭证，并以风险上限、KillSwitch、NodeFence 和精简状态变更记录形成安全边界。
- [原型验证事件编码与日志吞吐](issues/21-prototype-event-codec.md) — 采用 56 字节版本化记录头、变长 payload、逐记录 CRC32C、连续分片序号和提交 footer；四分片持续容量在本机原型成立，Linux/io_uring 四流突发及 SPSC P99 保留为生产准入测试。
- [原型验证 Python Strategy Host](issues/22-prototype-python-strategy-host.md) — 四个隔离 Host 各承载约 25 个中低频策略，以双 SPSC、订阅合并、时效/序号落后检测及 StrategyCheckpoint + 重放安全恢复；真实策略和 Zig 原子通道保留为生产准入测试。
- [定义可观测性与性能验收契约](issues/23-observability-and-benchmark-contract.md) — 以全量端到端分布、四类强制负载、六组运行信号、连续三次资格运行和正确性优先的硬失败条件验收；遥测失明停止新增风险，发布还须通过相对基线及观测开销门槛。
- [定义高可用 RTO、RPO 与故障切换政策](issues/24-ha-rto-rpo-and-failover.md) — EconomicRPO 为零，非计划 ReplayRPO 每分片限 50 ms/25,000 事件；使用短 PrimaryLease、外部 NodeFence、有限自动提升和完整 FailoverAdmission，且不要求固定周期生产切换演练。
- [定义策略状态迁移与回滚契约](issues/25-state-migration-and-rollback.md) — 仅显式迁移版本化策略私有状态；所有版本切换先撤单对账并在序号屏障原子激活，回滚只恢复旧代码而不回退任何经济事实。
- [定义生产操作生命周期](issues/26-operator-lifecycle-workflows.md) — 使用五阶段运行模式和独立安全栅栏统一启动、暂停、减仓、停机、恢复、发布与应急流程；只有可自证连续的故障自动恢复，其余均锁存并由单一 SystemOwner 确认。
- [选择研究数据存储与查询技术](issues/27-research-storage-technology.md) — 稳定二进制事件段承担 SourceArchive 与 replay，Parquet + 内嵌 DuckDB 承担 scan，SQLite WAL catalog 在本地 POSIX 文件系统上原子发布；首版不引入对象存储或 lakehouse 服务。
- [定义保证金归属、强平距离与抵押品边界](issues/28-margin-liquidation-and-collateral.md) — 策略按毛额独立占用 USDT 保证金，账户按 Venue 净仓位核对并禁止消费跨策略净额收益；使用版本化 MarginModel/Rules、双层安全余量、双 Reduce-only 与独立强制成交事实。
- [定义完整事件分类、字段与兼容性契约](issues/29-event-taxonomy-and-schema-compatibility.md) — 冻结 8 个事件家族、46 个永久类型及 v1 payload，采用 64/64/32 字节稳定日志容器、显式双表示、失败关闭语义重放和两阶段 schema 激活，并隔离真实、测试与模拟事实。
- [研究首批 Venue 保证金规则与接口矩阵](issues/35-research-venue-margin-rules.md) — 四家均须使用独立版本化 MarginRules；Gate.io 字段最完整，Binance/OKX/Bitget 仍有公式或扣减额缺口，强平价只作对账参考，自动追加与全部边界舍入必须按 Venue 差分验证。
- [原型验证定点保证金与强平求解](issues/36-prototype-fixed-point-margin-engine.md) — Gate.io 样本证明纯定点同核可覆盖杠杆/档位、挂单最坏场景、双层预测 buffer、按 tick 强平、双 Reduce-only 和强制执行经济闭合；正式全链路延迟与 Venue 等价性仍须资格测试。
- [定义跨 Venue 订单能力降级语义](issues/37-cross-venue-order-capability-degradation.md) — 适配器不得静默降级或跨所改投；使用显式能力/规范化/部分执行政策、非原子逐项 Batch、无重叠 CancelConfirmCreate、证据驱动重试和保守风险占用统一四家订单差异。

## Not yet specified

- 暂无；已能明确表述的业务逻辑问题均已形成票据。

## Out of scope

- 股票、传统期货、期权、DEX 和链上执行；它们需要独立的领域地图。
- 第一阶段的 FPGA、DPDK/XDP 内核旁路和多区域双活。
- 具体盈利策略、Alpha 有效性及收益保证。
- 在本地图阶段编写生产实现、交易所密钥或进行真实下单。
- 为尚未验证的扩展需求建设通用插件框架、全局 MPMC 事件总线或自研数据平台。
- [确定生产进程拓扑、CPU/NUMA 布局与内存预算](issues/30-process-topology-cpu-numa-memory.md) — 生产进程、绑核、NUMA 和精细内存预算延后到生产工程地图。
- [研究控制面与部署技术候选](issues/31-research-control-plane-technology.md)与[选择控制面实现与部署机制](issues/32-choose-control-plane-and-deployment.md) — 当前只保留控制命令业务契约，不做外围技术选型。
- [原型验证生产操作界面](issues/33-prototype-operator-interface.md) — 当前只规划操作语义，不制作生产 UI。
- [原型验证研究数据扫描、回放与目录发布](issues/34-prototype-research-storage-and-replay.md) — 当前保留数据与重放契约，不验证生产存储参数。

## Continuation

核心业务逻辑规格已完成；下一阶段转入[实现确定性交易引擎最小纵向闭环](../quant-trading-engine-vertical-slice/map.md)，不再在本地图追加实现票据。
