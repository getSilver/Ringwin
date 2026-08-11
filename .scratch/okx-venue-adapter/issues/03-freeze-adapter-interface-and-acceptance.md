# 冻结 Venue Adapter interface 与验收合同

Type: grilling
Status: resolved
Assignee:
Blocked by: 01, 02
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

基于当前 OKX 与 Zig 传输证据，Venue Adapter interface 应以哪些最小输入、输出、生命周期、背压、错误和时间语义隐藏具体传输实现，并以哪些离线、公共行情、Demo 私有及完整交易链轨迹证明 SimVenue 与 OKX Adapter 可替换而不污染 TradingShard？

## Answer

### 1. Module seam 与四操作 interface

Venue Adapter 是共享 Execution Gateway 外围的深 module。它以双向有界异步 seam 隔离 TradingShard 与具体 Venue implementation：TradingShard 只产生规范 OrderCommand、接收 CanonicalEvent，不观察 REST、WebSocket、签名、libcurl callback、OKX 字段、重连或分页。

外部 interface 只暴露四个操作：

- `start(AdapterConfig)`：启动单一 adapter/transport owner；配置只含 Venue 环境、ExchangeAccount、Instrument 白名单、CapabilityProfile/规则版本、订阅、队列及超时等非秘密内容和 CredentialIdentity，密钥通过不可记录的本机 credential provider 取得。
- `trySend(AdapterRequest)`：非阻塞提交规范 OrderCommand、订阅配置、版本化配置激活或明确 Reconciliation 请求；不得接受 OKX 原始参数或任意通用请求。
- `tryDrain(AdapterOutputBatch)`：由外围 dispatcher 批量拉取 AdapterIngressBatch、OrderDispatchResult 及 OperationalEvent；callback 不得进入 TradingShard。
- `stop(DrainDeadline)`：停止接收普通新增风险请求，允许安全命令和必要对账在期限内排空；期限届满后未解释发送保持 Unknown 并失败关闭。

SimVenue 与 OKX Adapter 均满足同一 interface。首版不建立 Venue 注册表、插件系统、通用 RPC 或为后续 Venue 预留的抽象层。

### 2. 输入、输出与证据顺序

- 唯一 Execution Gateway producer 按稳定顺序提交不可变 AdapterRequest；Adapter 的单 owner 线程独占 libcurl easy/multi handle。
- 每个外部原始帧形成一个 AdapterIngressBatch：稳定 RawIngressRecord、由它规范化出的零到多条 CanonicalEvent，以及来源会话、配置版本和既定四时间字段。
- RawIngressRecord 必须先成功进入 RawIngressStream，随后相关 CanonicalEvent 才可路由到 TradingShard；ExecutionReport、Fill 等事件保持对原始证据的引用。
- 原始帧损坏、未知 schema、字段冲突或无法规范化时保留原始证据并失败关闭，不输出猜测事件。
- 由本机 adapter 状态变化产生的 OrderDispatchResult/OperationalEvent 不伪造 RawIngressRecord，并通过 AdapterOutputBatch 独立输出。

### 3. 就绪与生命周期

不提供单一 `ready` 布尔值，也不建立平行运行模式。Adapter 通过既有 OperationalEvent/SafetyGate 分别表达：

- PublicMarketReady：目标 Instrument 已取得有效规则并完成连续 L2 同步；
- PrivateStreamReady：目标私有 WS 会话已认证并订阅；
- ReconciliationReady：订单、成交、余额、仓位、分页和全部 Unknown 已解释；
- OrderEntryReady：Demo 环境、Credential、账户/持仓/保证金配置、限流及全部适用安全条件成立。

只有 OrderEntryReady 允许扩大风险；降级期间仍须接收事实，并为 Cancel、VenueReduceOnly、DeRisk 和必要对账保留通路。启动和私有重连采用 WS 缓冲加 REST bootstrap/reconciliation，不能把 orders WS 当初始快照或恢复日志。

### 4. 背压

- 普通 Submit 和扩大风险 Amend 使用有界普通队列；满时形成 `NotSent/AdapterBackpressure`，不得进入 libcurl、不得形成 Unknown。
- Cancel、VenueReduceOnly、DeRisk 和必要 Reconciliation 使用独立预留容量，普通请求不能耗尽安全通路。
- 队列不得无限增长，TradingShard 不得等待 Adapter。
- RawIngress 持久化或输出队列阻塞立即撤销 OrderEntryReady。
- 公共行情丢失形成明确 Gap 并重新同步；私有事实不能丢弃，接收完整性无法证明时断开会话并经 REST 全量对账后恢复。

### 5. Dispatch、错误与恢复

- AdapterRequest 成功入队不产生 OrderDispatchResult。
- 在能够证明未触网时产生 NotSent；到期为 `NotSent/DeadlineExpired`，背压为 `NotSent/AdapterBackpressure`。
- 请求可能已发出但没有权威结果时一律 Unknown；禁止自动重放交易 POST。
- 成功 REST/WS ACK 只形成 Submitted，不证明 Venue 接受；最终订单状态只来自 ExecutionReport、Fill 或 OrderReconciliationResult。
- 错误通过既有 CanonicalRejectReason/稳定 dispatch 原因表达；原始 OKX code、文本、请求哈希和非秘密协议证据保留在接入记录，不泄漏给策略。

### 6. 时间合同

完整继承[确定统一执行、事件顺序与时间模型](../../quant-trading-system/issues/06-determinism-ordering-and-time.md)：

- source_time 是外部来源声明时间；receive_time 是外部事实首次进入系统时采集的 UTC 时间；缺失均通过 presence bit 表达。
- monotonic_time 用于本机排序、deadline、超时、心跳、退避和延迟，只能在同一 MonotonicEpochIdentity 内比较。
- wall_time_utc 是事件实际记录的审计时间；UTC 不用于本地超时、租约期限或事件排序。
- 重放保存全部原时间并只以虚拟时钟产生 TimerEvent。
- DispatchDeadline 在进入普通队列前及真正加入 libcurl handle 前检查；首次发送前过期才是 NotSent，Submitted/Live 后不自动撤单。
- OKX server-time offset 只用于签名时钟健康检查；偏差超限撤销 OrderEntryReady，不改变 EventEnvelope 时间语义。

当前产品原型日志只编码 source/receive/monotonic 三个时间，尚未实现 EventEnvelope v1 要求的 wall_time_utc 和 presence bits；真实链路接入前必须补齐。

### 7. 验收合同

1. 离线 interface 合同：验证有界队列、背压、四时间、dispatch 分类、RawIngress 先持久化、codec 确定性及秘密不进入输出。
2. SimVenue 回归：既有 happy path、market gap、risk rejection、Unknown reconciliation、idempotency 和 replay 全部改走同一 interface，权威摘要不变。
3. OKX 公共验收：无凭证运行 SPOT/SWAP Instrument、L2、mark/funding、序号缺口与重连。
4. Demo 私有只读验收：认证、orders/fills/balance/positions bootstrap、断线缓冲和 REST 对账，全程不下单。
5. 显式 `--demo-live`：在既定白名单、名义上限、前置对账和清理栅栏下覆盖完整既定订单能力、可审计故障注入、端到端 TradingShard 投影、撤单及 Reduce-only 清仓；Windows 全部通过并保持 `x86_64-linux-gnu` 可交叉构建。

任一层失败都不能关闭 OKX Adapter 地图；Adapter 单测不能替代完整交易链验收，Windows 结果不能宣称 Linux 性能或生产资格。

## Comments

- 2026-08-11：SystemOwner 确认双向有界异步 seam、RawIngress 优先、分离就绪、背压、既有时间模型、四操作 interface 与五层验收合同。
