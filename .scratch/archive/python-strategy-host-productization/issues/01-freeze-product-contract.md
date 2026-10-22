# 冻结 StrategyHost 产品 seam 与验收轨迹

Type: grilling
Status: resolved
Blocked by:
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

在写产品 IPC 前，哪些进程所有权、原子桥边界、稳定 batch/intent schema、身份、
时间点和 acceptance traces 必须冻结，才能证明 Python 永远是 TradingShard 外围的
不可信策略计算器，而不是权威交易状态旁路？

## Scope

- 冻结 Zig 进程、StrategyHost、StrategyInstance、supervisor 与共享内存对象的所有权。
- 在“Zig 拥有 acquire/release 游标”的既定原则下，选择 Python 调用原子操作的最小产品桥，
  并明确平台 ABI、生命周期和崩溃清理边界。
- 冻结 Host 握手、HostSessionIdentity、HostBatchSequence、ShardSequence、
  StrategyCursor、StrategyInstanceIdentity 与 OrderIntentIdentity。
- 冻结输入 batch、输出 intent、checkpoint 和控制消息的 V1 字段、比例尺、长度及校验。
- 冻结正常、异常、落后、旧会话、损坏、输出满、崩溃和恢复轨迹及 StateDigest/游标断言。
- 明确回测、仿真和实盘如何共用同一 Host 协议，不建立直接 Python 调用旁路。

## Done when

- 可以仅按冻结 fixture 实现后续票，不再猜测 IPC 所有权、schema 或恢复终态。
- 每条失败轨迹明确禁止行为、权威事实、恢复屏障和可运行断言。
- SystemOwner 确认产品 seam；尚未由真实负载证明的参数保留为资格项而非伪装成决定。

## Confirmed decisions

### StrategyHostAtomicBridge 与复制边界

- V1 使用 Zig 实现的最小 C ABI `StrategyHostAtomicBridge`，由 Python 标准库
  `ctypes` 调用；不引入 CPython 扩展框架或第三方 IPC 依赖。
- acquire/release 游标操作、槽位边界检查和发布顺序只在 Zig 桥内执行。
  Python 不直接读取、写入或缓存原子游标。
- 核心到 Host：桥从已 acquire 的共享槽位有界复制到 Python 自有只读
  `bytes`，复制成功后才 release 输入槽位。
- Host 到核心：Python 先形成完整 `bytes`，桥在确认输出槽位可用后有界复制，
  最后以 release 语义发布；复制或校验失败不得发布半条 intent。
- 单个语义事件回调的多个独立 frame 通过有界 `try_publish_many` 一次预留、逐槽复制，
  最后只发布一次 producer cursor，消费者只能看到全组或零组。
- Python 永不获得共享内存指针、槽位 `memoryview` 或跨回调借用权，因此策略不能
  在槽位复用后观察被覆盖的数据。
- 每方向一次复制是明确的安全边界，不属于 native 核心的 10 us 合同。只有产品
  资格测试证明它成为 PythonDecisionLatency 或吞吐瓶颈，才另开决策重新评估受控
  零拷贝；V1 不预留双模式接口。

### 进程与资源所有权

- 单个活动 Zig TradingEngine 进程承载 4 个 TradingShard；每个 TradingShard
  唯一对应一个独立 Python StrategyHost 进程，首版目标约 25 个 StrategyInstance。
- StrategyInstance 是 Host 内的逻辑实例，不为每个策略建立子进程或专用线程。
- 每个 TradingShard 拥有一个内置 HostSupervisor。它负责对应 Host 的启动、
  存活检测、会话失效、终止和重建。
- 操作系统服务管理器只监管 TradingEngine。Host 是 TradingEngine 的子进程，
  Linux 使用父进程死亡约束，Windows 使用 Job Object，确保父进程退出时回收 Host。
- HostSupervisor 唯一创建、初始化和删除共享内存对象；Python Host 只能映射启动时
  继承的匿名 fd/handle，不得创建、重置、按名称重新打开或 unlink。
- 每次 Host 启动均使用新的 HostSessionIdentity 和新的会话资源。重启顺序为：
  先在 TradingShard 内失效旧会话并关闭其交易授权，再终止/回收旧 Host 与共享内存，
  最后创建新会话；不得复用旧游标或通过 PID 识别会话。

### 启动握手与 HostActivationBarrier

- Host 启动采用 Compatibility、Recovery、Activation 三阶段；进程成功启动不等于
  获得交易授权。
- Compatibility：Host 回传 HostSupervisor 预先签发的 HostSessionIdentity，以及
  协议版本、SchemaRegistryId、DecisionDomain、Host 构建身份和策略清单摘要。
  TradingShard 只接受与启动计划完全相等的组合，不做版本降级或运行时 schema 协商。
- Recovery：Host 加载启动计划指定的 checkpoint，并按 TradingShard 提供的确定
  日志无权重放至目标 BarrierSequence；每个 StrategyInstance 回报 StrategyCursor、
  状态 schema 身份和 StateDigest。恢复期间输出通道保持关闭，任何 OrderIntent 均
  视为协议违规。
- Activation：TradingShard 验证策略身份、配置、游标、状态摘要和恢复屏障 B 后，
  在 ShardSequence A 记录权威 `HostActivated` 事实并发送 ActivateStrategy。Host
  继续无权应用至 A，实际应用该事实后才开启输出；只有 cursor>A、绑定当前 session
  与 StrategyActivationIdentity 的 intent 才可进入既有风控/OMS 路径。
- 单个策略 checkpoint、迁移或重放失败时只禁用该 StrategyInstance；同 Host 中已
  验证的其他策略可以分别激活。Host 级协议、schema、DecisionDomain 或会话错误则
  使整个会话失败并由 HostSupervisor 重建。

### 身份、序号与幂等空间

- HostSessionIdentity 是显式三元组：EngineFencingToken、TradingShardId、
  HostGeneration。HostGeneration 在同一 fencing token 和 shard 内单调递增；
  任一分量变化即为新会话。
- HostBatchSequence 是会话内从 1 严格连续递增的 `u64` 传输序号。它只检测重复、
  乱序和缺口，重启后重新开始，不进入 checkpoint 或业务幂等身份。
- ShardSequence 是 TradingShard 权威决策日志中持续递增的 `u64`；Host 重建不
  改变它。StrategyCursor 是每个 StrategyInstance 已完整应用的最后一个
  ShardSequence，不能由“收到批次”推导，只有成功应用后才能前移。
- StrategyInstanceIdentity 是控制面分配的稳定 128 位逻辑身份。Host、参数版本和
  checkpoint 变化不改变它；只有显式创建 StrategySuccessor 才使用新身份。
- OrderIntentIdentity 是 StrategyInstanceIdentity 与 `u64 IntentSequence` 的组合。
  IntentSequence 从 1 开始，属于 PortableStrategyState，每创建一条意图恰好前移
  一次。恢复重放必须执行同一路径并产生相同身份，但在 HostActivationBarrier 前
  禁止发布。
- 每条 intent 另带 HostSessionIdentity、HostBatchSequence 和 StrategyCursor
  作为当前传输与授权证据；它们不进入 OrderIntentIdentity。会话重建因此不能把
  重放出的同一业务意图伪装成新订单。

### StrategyInputBatch 的确定性边界

- StrategyInputBatch 只是 IPC 传输容器，HostBatchSequence 和分批边界均不暴露给
  用户策略，也不得触发策略决策。
- 相邻 batch 的 ShardSequence 覆盖范围必须连续：
  `next.first_shard_sequence == previous.last_shard_sequence + 1`。首批起点由握手的
  恢复或激活计划明确指定。
- batch 内携带的事件按 ShardSequence 严格递增，均须位于声明的 first/last 范围；
  订阅路由可以省略与该 Host 无关的事件，因此记录序号不要求逐条连续。
- Host runtime 按事件顺序分发语义回调；提交粒度是单个语义事件，而不是 transport
  batch。回调正常返回且该事件的暂存输出完成发布后，策略 cursor 才前移至该事件；
  只有全部目标事件均成功时才最终到达 batch last_shard_sequence。异常策略单独禁用，
  cursor 保持在最后成功事件，不得伪装到 batch 末尾。
- 恢复可以改变 IPC 分批方式，但必须产生相同的事件回调序列、OrderIntentIdentity
  推进和最终 StateDigest。原型中以 batch 序号充当策略进度的做法不得进入产品。
- V1 不提供用户级 `on_batch`。未来如需批量决策语义，必须引入进入分片决策日志的
  显式 StrategyEvaluationEvent，而不能复用偶然的 IPC batch 边界。

### StrategyInputBatch v1 线级格式

全部整数小端编码；编码器逐字段写入，禁止直接复制 Zig/Python 内存对象。batch
最大总长 1,048,576 字节、最多 4,096 条事件。实际共享内存 slot 大小和 ring 深度
是产品资格参数，不在本票伪装为已证明值，但 slot 必须容纳完整 batch，V1 不支持
压缩或跨 slot 分片。

#### BatchHeader v1：128 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: [4]u8 = "QSHB"` |
| 4 | `protocol_version: u16 = 1` |
| 6 | `header_len: u16 = 128` |
| 8 | `flags: u32 = 0` |
| 12 | `total_len: u32` |
| 16 | `schema_registry_id: u128` |
| 32 | `decision_domain_identity: u128` |
| 48 | `engine_fencing_token: u64` |
| 56 | `trading_shard_id: u32` |
| 60 | `reserved0: u32 = 0` |
| 64 | `host_generation: u64` |
| 72 | `host_batch_sequence: u64` |
| 80 | `first_shard_sequence: u64` |
| 88 | `last_shard_sequence: u64` |
| 96 | `published_monotonic_ns: i64` |
| 104 | `event_count: u32` |
| 108 | `payload_len: u32` |
| 112 | `reserved1: [12]u8 = 0` |
| 124 | `batch_crc32c: u32` |

`total_len == 128 + payload_len`。CRC32C 依次覆盖 header `[0,124)` 和 payload
`[128,total_len)`；CRC 字段自身不参与。未知 flags、非零 reserved、长度/计数运算
溢出或超出已握手 slot capacity 均拒绝。存在新 ShardSequence 覆盖时
`first <= last`；即使订阅过滤后 `event_count == 0`，该范围仍有效。没有新范围时
不发送空 batch。

#### EventRecordHeader v1：64 字节

| Offset | 字段 |
|---:|---|
| 0 | `record_len: u32` |
| 4 | `payload_len: u32` |
| 8 | `event_type: u16` |
| 10 | `schema_version: u16` |
| 12 | `flags: u32` |
| 16 | `shard_sequence: u64` |
| 24 | `source_time_ns: i64` |
| 32 | `receive_time_ns: i64` |
| 40 | `monotonic_time_ns: i64` |
| 48 | `wall_time_utc_ns: i64` |
| 56 | `reserved: u64 = 0` |

payload 紧随 header；`record_len` 包含 64 字节头、payload 和补齐到 8 字节边界的
零 padding，且 `record_len >= 64 + payload_len`。flags 只复用稳定 EventEnvelope
中已定义的时间 presence bits，其他位拒绝；缺失时间编码为零但不得解释为真实时间。
事件不重复携带 CRC，整批 CRC 已覆盖 record header、payload 和 padding。

桥在复制前验证 batch 结构、长度、整数运算、当前 session、批次/分片覆盖连续性和
CRC，并以同一平台单调时钟检查 `published_monotonic_ns`；年龄超过 50 ms 时返回
stale 状态而不把 payload 交给 Python。Python codec 继续验证注册表中的
EventType/SchemaVersion、精确 payload、枚举、比例尺、排序和领域不变量。

### StrategyOutputFrame v1 线级格式

每个 frame 只承载一条独立 OrderIntent，或一个完整 IntentGroup 及其全部有序成员。
多个独立 intent 使用多个 frame；IntentGroup 不得跨 frame/slot。frame 最大总长
262,144 字节，组成员数为 2 至 64。V1 不支持压缩或分片。

#### OutputFrameHeader v1：128 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: [4]u8 = "QSHO"` |
| 4 | `protocol_version: u16 = 1` |
| 6 | `header_len: u16 = 128` |
| 8 | `flags: u32 = 0` |
| 12 | `total_len: u32` |
| 16 | `schema_registry_id: u128` |
| 32 | `engine_fencing_token: u64` |
| 40 | `trading_shard_id: u32` |
| 44 | `reserved0: u32 = 0` |
| 48 | `host_generation: u64` |
| 56 | `source_host_batch_sequence: u64` |
| 64 | `strategy_instance_identity: u128` |
| 80 | `strategy_cursor: u64` |
| 88 | `strategy_config_version: u64` |
| 96 | `payload_event_type: u16` |
| 98 | `payload_schema_version: u16` |
| 100 | `item_count: u32` |
| 104 | `payload_len: u32` |
| 108 | `strategy_activation_identity: u128` |
| 124 | `frame_crc32c: u32` |

`total_len == 128 + payload_len`。CRC32C 依次覆盖 header `[0,124)` 与 payload
`[128,total_len)`。独立 OrderIntent 的 `item_count == 1`；IntentGroup 的
`item_count` 等于成员数。payload 复用 SchemaRegistry 中唯一的稳定
OrderIntent/IntentGroup schema，不定义 Python 专用订单表示。

所有价格、数量、金额和时间复用权威定点整数、比例尺及单位；拒绝 `f64`、数值字符串、
未知 flags、非零 reserved、未知 schema、非规范编码和超限数组。Python 只能提出
OrderIntent 语义，不得填写或伪造 RiskDecision、RiskLease、RiskReservation、
OrderCommand、client order ID、EngineFencingToken 或执行网关字段。

TradingShard 在风控前重新验证 frame 结构/CRC、当前 session、当前
StrategyActivationIdentity、来源 batch 是否已发布、StrategyInstance/配置归属、
StrategyCursor、payload 身份及全部领域不变量。100 ms
新鲜度以核心保存的 `source_host_batch_sequence -> published_monotonic_ns` 计算，
不使用 Python 声明的时间。输出 ring 无完整 slot 时桥返回 `FULL` 且写入位置不发布；
禁止部分可见、覆盖未消费 frame 或静默丢弃。

### IntentGroupIdentity

- 创建含 N 个成员的 IntentGroup 时，StrategyInstance 从其 PortableStrategyState
  中一次性分配连续区间
  `[first_intent_sequence, first_intent_sequence + N - 1]`；成员按稳定组顺序逐一
  使用该区间，禁止部分推进。
- IntentGroupIdentity 是 StrategyInstanceIdentity 与 `first_intent_sequence`
  的组合，不增加独立 GroupSequence。单个成员仍以自身
  StrategyInstanceIdentity + IntentSequence 形成 OrderIntentIdentity。
- IntentGroup payload 记录成员数和完整有序 OrderIntentIdentity 列表。核心验证
  同一实例、连续序号、无重复、列表长度与 frame `item_count` 一致。
- 任一结构、身份或成员基础校验失败，整组在风控前拒绝。基础验证通过后的风险准入、
  部分成功和取消行为继续使用既定 Independent/CancelRemaining 规则。
- 输出满、Host 崩溃或无权恢复不得通过重新分配序号改变组身份；相同历史必须重建
  相同 IntentGroupIdentity 和成员身份。

### PortableStrategyStateJsonV1

- checkpoint 以单个 StrategyInstance 为单位；V1 不建立 Host 联合快照。
- 策略向 Host runtime 返回由其显式 StateSchema 定义的基础值，不能提交任意序列化
  bytes。Host runtime 是唯一编码入口。
- V1 payload 是无空白的规范 JSON 子集：允许 `null`、布尔、schema 指定位宽的
  有符号/无符号整数、UTF-8 字符串、定长或有界数组，以及字段集合和顺序均固定的
  object。bytes 字段按 schema 编码为小写十六进制字符串。
- 禁止浮点/NaN/Infinity、任意 map key、未声明/重复字段、动态类型、pickle、
  marshal、解释器对象和引用图。字段严格按 schema 顺序输出；解码后重新编码必须
  得到逐字节相同 payload。
- payload 最大 8,388,608 字节、最大嵌套 32 层；每个字符串、bytes 和数组还受
  对应 StateSchema 的更小上限约束。
- checkpoint 元数据绑定 StrategyInstanceIdentity、StateSchema identity/version、
  策略配置版本、StrategyCursor 和下一 IntentSequence。核心验证允许的 schema、
  容器边界、CRC32C 与 SHA-256；内容完整持久化并复读校验后，才能记录
  StrategyCheckpointPublished。
- checkpoint 编解码不属于订单热路径。只有资格测试证明状态大小或恢复耗时不合格，
  才发布独立二进制 payload 版本；V1 不预建双编码接口。

### CheckpointContainer v1 与传输原子性

- 两条共享内存 SPSC ring 只承载 StrategyInputBatch 与 StrategyOutputFrame。
  HostSupervisor 另建 Zig→Host、Host→Zig 两条匿名单向 pipe 作为
  StrategyHostControlChannel；子进程只继承必要端点，stderr 单独用于日志。
- pipe 使用有界长度前缀 control frame。每个 Host 同时最多一个 checkpoint 请求；
  checkpoint bytes 通过 Host→Zig pipe 流式传送，不建立第三块共享内存，也不占用
  intent ring。
- Host 只能响应当前 session 的 CheckpointRequest，不能自行指定路径、覆盖文件或
  发布 StrategyCheckpointPublished。checkpoint 容器不绑定 session，以保持跨
  Host 重建可移植；外层 control frame 负责验证生产会话。

#### CheckpointHeader v1：192 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: [4]u8 = "QSSC"` |
| 4 | `format_version: u16 = 1` |
| 6 | `header_len: u16 = 192` |
| 8 | `flags: u32 = 0` |
| 12 | `total_len: u32` |
| 16 | `schema_registry_id: u128` |
| 32 | `strategy_instance_identity: u128` |
| 48 | `strategy_definition_identity: u128` |
| 64 | `state_schema_identity: u128` |
| 80 | `state_schema_version: u32` |
| 84 | `payload_encoding: u16 = 1`（PortableStrategyStateJsonV1） |
| 86 | `reserved0: u16 = 0` |
| 88 | `strategy_config_version: u64` |
| 96 | `strategy_cursor: u64` |
| 104 | `next_intent_sequence: u64` |
| 112 | `payload_len: u32` |
| 116 | `payload_crc32c: u32` |
| 120 | `checkpoint_sha256: [32]u8` |
| 152 | `reserved1: [36]u8 = 0` |
| 188 | `header_crc32c: u32` |

`total_len == 192 + payload_len`，payload 上限 8,388,608 字节。
`checkpoint_sha256 = SHA-256(header[0,120) || payload)`，该值即
StrategyCheckpointIdentity；header CRC32C 覆盖 `[0,188)`，payload CRC32C 只覆盖
payload。next_intent_sequence 必须大于零，并与恢复后的 PortableStrategyState
及核心已观察意图空间一致。

- Zig 外围 I/O 线程验证长度、schema/session 请求上下文、CRC 和 SHA-256 后写入
  Zig 选择的临时文件；完整写入、flush、复读校验并原子改名成功后，才向 TradingShard
  提交 StrategyCheckpointPublished 事实。该事实只保存身份、元数据和受控存储引用。
- 截断、超长、未知格式/schema、摘要不符、Host 崩溃或临时文件失败均丢弃候选，
  最近一个已发布 checkpoint 保持有效。部分文件永不成为恢复来源。
- checkpoint 导出/编码不是订单热路径，但策略资格测试必须证明其不会使 Host 输入
  年龄超过 50 ms；不合格策略拒绝上线。V1 不为未证明需求建设异步对象快照框架。

### ControlFrame v1 与消息白名单

#### ControlFrameHeader v1：64 字节

| Offset | 字段 |
|---:|---|
| 0 | `magic: [4]u8 = "QSHC"` |
| 4 | `protocol_version: u16 = 1` |
| 6 | `header_len: u16 = 64` |
| 8 | `message_type: u16` |
| 10 | `schema_version: u16 = 1` |
| 12 | `flags: u32 = 0` |
| 16 | `total_len: u32` |
| 20 | `payload_len: u32` |
| 24 | `engine_fencing_token: u64` |
| 32 | `trading_shard_id: u32` |
| 36 | `reserved: u32 = 0` |
| 40 | `host_generation: u64` |
| 48 | `control_sequence: u64` |
| 56 | `payload_crc32c: u32` |
| 60 | `header_crc32c: u32` |

`total_len == 64 + payload_len`。header CRC32C 覆盖 `[0,60)`；payload CRC32C
覆盖 payload。ControlSequence 在每个方向、每个 HostSessionIdentity 内从 1 严格
连续递增。普通 payload 上限 65,536 字节；只有 BeginRecovery 携带的受验
CheckpointContainer 和 CheckpointCandidate 可以达到 checkpoint 容器上限。

Zig→Host 的 message_type 白名单：

- `SessionPlan`：DecisionDomain、协议/SchemaRegistryId、预期 Host build、完整 session、
  ring slot/capacity、心跳/超时资格参数，以及每个策略的实例/定义/配置/状态 schema、
  checkpoint 与订阅摘要。
- `BeginRecovery`：策略身份、checkpoint 容器、replay 起点与目标 BarrierSequence。
- `ActivateStrategy`：策略身份、已记录授权事实的 StrategyActivationIdentity、
  barrier、预期
  StrategyStateDigest。
- `DeactivateStrategy`：策略身份、稳定原因和核心已生效的撤权 ShardSequence。
- `CheckpointRequest`：request identity、策略身份和必须精确匹配的 StrategyCursor。
- `Shutdown`：稳定原因和单调 deadline。

Host→Zig 的 message_type 白名单：

- `HostHello`：实际 Host build、Python ABI、协议/注册表、session 和策略清单摘要。
- `StrategyRecovered`：策略/配置/schema、cursor、next IntentSequence 与
  StrategyStateDigest。
- `StrategyFaulted`：策略身份、阶段、稳定错误类别、最后有效 cursor 和最多 4 KiB
  诊断；原始 traceback 只进 stderr 日志。
- `RecoveryRequired`：Host 或策略范围、稳定原因、最后有效 batch/cursor。
- `CheckpointCandidate`：request identity 与完整 CheckpointContainer。
- `HostHeartbeat`：主事件循环最近完成的 HostBatchSequence 和各策略 cursor 摘要；
  接收时间由 Zig 自己测量。
- `ShutdownAck`：已停止策略回调及输出的确认。

参数变更继续使用可重放 ConfigEvent。市场、账户、订单、风控、账本和执行事实不得
进入控制 channel；未知方向/类型/version/flags、旧 session、序号 gap 或 CRC 错误
使会话失败关闭。ActivateStrategy 只是核心权威事实后的运行通知，不能自行授予权限。
heartbeat 必须由 Host 主事件循环产生，独立线程不得维持假活性；具体 interval/timeout
由部署资格确定。

### StrategyStateDigest v1

StrategyStateDigest v1 是下列无歧义字节串的 SHA-256；引号内为 ASCII domain
separator，整数使用本票已冻结的小端宽度：

```text
SHA-256(
  "QSSD\x01" ||
  SchemaRegistryId ||
  StrategyInstanceIdentity ||
  StrategyDefinitionIdentity ||
  StateSchemaIdentity ||
  StateSchemaVersion:u32 ||
  StrategyConfigVersion:u64 ||
  StrategyCursor:u64 ||
  next_IntentSequence:u64 ||
  payload_len:u32 ||
  canonical_PortableStrategyStateJsonV1_bytes
)
```

它是策略私有逻辑状态摘要，不等于 checkpoint 容器的 StrategyCheckpointIdentity、
传输 CRC32C 或核心 AuthoritativeTradingState 的 CanonicalStateDigest。

- 恢复起点必须逐项匹配已发布 checkpoint 的身份、payload、CRC/hash 与
  StrategyStateDigest。
- replay 到 barrier 后重新规范编码并计算摘要。蓝绿、热备或 VerificationReplay
  已给出 expected StrategyStateDigest 时必须完全相等，否则不得激活。
- 普通崩溃恢复若该 barrier 没有历史 expected digest，则验证 schema、策略自定义
  状态不变量和确定编码，并把 observed digest 记录到 HostActivated；不得把“成功
  计算”报告成“已与未知参考值相等”。
- 生产资格必须从相同 checkpoint 对相同事件范围执行两次独立恢复，断言最终 digest、
  StrategyCursor、next IntentSequence 和生成的 OrderIntentIdentity 序列逐项相等。

### Acceptance trace 基线

#### AT-NORMAL-01：checkpoint + replay + activation + intent 幂等

Fixture 起点：Strategy A 的有效 checkpoint 位于 StrategyCursor 100，
`next_intent_sequence == 7`；TradingShard 当前恢复 barrier 为 120。

1. 新 HostSessionIdentity 完成 Compatibility 并进入 Recovery。
2. TradingShard 通过 StrategyInputBatch 将 ShardSequence 101..120 重放到 Host；
   IPC 可以使用不同分批，但语义事件顺序不变。
3. 恢复期间策略执行与连续运行相同的状态迁移及 IntentSequence 推进，但
   StrategyOutputFrame 发布数保持零。
4. Host 在 cursor 120 回报 StateSchema、next IntentSequence 与
   StrategyStateDigest；同 checkpoint/事件范围的第二次独立恢复得到逐项相同结果。
5. TradingShard 验证结果，在 ShardSequence A 记录 HostActivated，再发送
   ActivateStrategy；Host 无权应用至 A 后才进入 Active。
6. A+1 以后的语义事件触发新 intent；frame 绑定当前 session、来源 batch、cursor、配置和
   确定性 OrderIntentIdentity。核心在 100 ms 新鲜度内完成基础验证，只记录一次
   OrderIntent 事实，再进入既有风险/OMS。
7. 测试重复提交同一完整 frame，核心返回已记录结果，不重复生成风险占用、命令或订单。

必须断言：

- `accepted_intent_count_before_activation == 0`。
- cursor 只在完整应用 batch 后前移，恢复终点严格等于 120。
- 两次恢复的 StrategyStateDigest、next IntentSequence 和历史
  OrderIntentIdentity 序列完全一致。
- Host 恢复不改变核心 CanonicalStateDigest。
- 激活后首个新 OrderIntentIdentity 与无崩溃连续运行对照轨迹一致。
- duplicate frame 只关联既有 OrderIntent 结果，权威订单/风险计数不增加。

fixture 可以选择恢复区间内实际产生的历史 intent 数量；具体序号不是协议常量，但
必须由连续运行对照轨迹证明。

#### AT-STRATEGY-EXCEPTION-01：单策略失败隔离

Fixture：同一 Host 内 Strategy A、B 均已激活并处理至 cursor 104。A 在处理
ShardSequence 105 时先产生临时 intent，随后抛出 Python 异常；B 正常处理同一输入。

1. Host runtime 为每个语义事件回调建立仅位于 runtime 的输出暂存区；用户策略不能
   直接写 output ring。
2. 只有回调正常返回后，runtime 才按稳定顺序发布暂存输出；全部所需输出发布完成后，
   再把该策略 cursor 提交至该事件 ShardSequence。
3. A 抛出异常时，105 的暂存输出全部丢弃，当前 Python 状态对象整体作废，不尝试
   回滚任意对象图；A cursor 保持 104，并进入 Faulted/Disabled。
4. runtime 跳过 A 的后续回调，继续让 B 及其他策略处理 batch。普通策略异常不改变
   HostSessionIdentity，也不重启 Host。
5. Host 发送 StrategyFaulted，包含稳定阶段/错误类别、cursor 104 和有界诊断；
   traceback 只写 stderr。A 仅在新代码/配置或明确恢复操作后重建，禁止自动崩溃循环。

必须断言：

- A 在失败回调 105 产生的 StrategyOutputFrame 数为零，cursor 严格为 104。
- B 到达 batch last_shard_sequence，其输出与无 A 异常的对照轨迹一致。
- Host 主循环/heartbeat、session 和其他策略授权不变。
- 核心没有因 A 失败产生 OrderIntent、RiskReservation、OrderCommand 或订单变化。
- 从最近 checkpoint 重放 A 至 105 稳定复现同一错误类别，且不产生不同 intent 身份。

#### AT-HOST-LOSS-01：Host crash / 不可抢占 hang

crash 由子进程退出句柄检测；hang 由主事件循环 heartbeat 在部署资格化 timeout 内
不再推进检测。两者采用相同恢复状态机：

1. TradingShard 先失效 HostSessionIdentity、撤销该 Host 全部策略的有效交易权限，
   并停止向旧 input ring 发布。
2. hang 场景随后终止整个 Python Host；有界宽限期后仍未退出则强制 kill，不尝试
   在线中断单个 Python 回调。
3. HostSupervisor 回收旧 control pipe/共享内存，创建全新 session 和 IPC 对象。
4. 各 StrategyInstance 从最近有效 checkpoint 无权重放至新 barrier，分别验证并
   激活；其他 TradingShard/Host 持续运行。

竞态 fixture 必须分别注入：

- **AcceptedBeforeFence**：旧 intent 已由核心接受。它保持权威；新 Host 重放产生
  相同 OrderIntentIdentity 并只命中既有幂等结果。
- **PublishedButNotAccepted**：frame 只在旧 output ring 可见。session 失效后核心
  拒绝它；新 Host 重放可在新 session 重新提交同一业务身份，并且只接受一次。

必须断言：

- session 失效后旧 frame 的 accepted count 为零；每个 OrderIntentIdentity 最多
  形成一次权威 OrderIntent/RiskReservation。
- 新 HostSessionIdentity、pipe 和共享内存对象均不同，旧 cursor/slot 不复用。
- 新 session 恢复期间 accepted intent 为零。
- 非故障 Host 的 cursor、授权和输入发布不中断。
- crash 与 hang 从同一最后有效 cursor 恢复出相同 StrategyStateDigest、
  next IntentSequence 和 intent 身份序列。
- timeout 数值来自部署资格参数；fixture 通过受控停顿触发，不把测试值变成协议常量。

#### AT-INPUT-INVALID-01：stale / gap / 损坏 / 未知 schema

Host runtime 必须在任何用户回调前完成整批结构、所有 record schema 及领域校验；
禁止边解析边调用策略。下列任一输入使整个 HostSessionIdentity 失效并重建：

- bridge pickup 时 `batch_age > 50_000_000 ns`；
- HostBatchSequence 重复、倒退或 gap；
- first/last ShardSequence 与上一覆盖范围不连续；
- 长度、计数运算、CRC、padding、flags 或 reserved 非法；
- 未知 EventType/SchemaVersion，或任一 payload 严格领域验证失败。

失败 batch 的全部事件 callback/output 数均为零，所有策略 cursor 保持最后成功位置。
V1 不跳过坏事件、不重置 ring cursor、不在同一 session 继续；新 session 从最近有效
checkpoint 和完整分片日志恢复。合法的 `event_count == 0` 覆盖 batch 不属于失败。

fixture 分别注入 stale、HostBatchSequence gap、ShardSequence 覆盖 gap、CRC bit flip
及 unknown schema，并断言：

- 失败 batch `callback_count == 0 && output_frame_count == 0`。
- 相关 StrategyCursor 均不前移，旧 session 后续输入/输出全部拒绝。
- 非故障 Host 不受影响。
- 新 session 恢复后的 StrategyStateDigest、cursor、next IntentSequence 与 intent
  身份序列等于 AT-NORMAL-01 对照。
- `50_000_000 ns` 边界仍可接收，`50_000_001 ns` 必须 stale，禁止毫秒取整歧义。

#### AT-OUTPUT-FULL-01：单回调输出原子发布

- 每个语义事件回调最多返回 64 个独立 StrategyOutputFrame；一个完整 IntentGroup
  计为一个 frame。
- 回调成功后 bridge `try_publish_many` 先验证全部 frame 与总长度，再确认 N 个连续
  可写槽位；全部复制完成后以一次 release-store 前移 producer cursor。
- 可用槽位不足时返回 FULL，本回调新增 frame 全部不可见，StrategyCursor 不前移。
  V1 不等待、不覆盖、不在同一 session 重试。
- FULL 表示 Host 级输出通道失去及时交付能力，触发整个 session 失效并从最后成功
  cursor 重建。超过 64 个 frame 则是该策略的 OutputLimitExceeded，按
  AT-STRATEGY-EXCEPTION-01 单策略隔离。
- 复制过程中 Host 崩溃、但 producer cursor 尚未发布时，消费者不得观察任何新 frame。

fixture 预填 ring，使空闲槽位为本次 N 个输出的 `N - 1`，并断言：

- producer cursor、可见 frame 数和策略 cursor 均不改变；
- 旧 session 被失效，非故障 Host 不受影响；
- 新 session 重放产生相同 frame/OrderIntentIdentity，最终每个业务身份恰好接受一次；
- 在每个槽位复制点注入 crash，release-store 之前始终为零可见，之后全部可见。

#### AT-OUTPUT-STALE-OLD-01：decision stale 与旧授权输出

OutputFrame v1 offset 108 的 16 字节不再 reserved，固定为
`strategy_activation_identity: u128`。它等于当前策略 HostActivated 权威事实的
身份；撤权立即失效，同一 HostSession 内重新激活也产生新身份。

- 核心以来源 HostBatchSequence 对应的可信发布时间计算 decision age。
  `age <= 100_000_000 ns` 可继续验证；`100_000_001 ns` 必须在风控前拒绝。
- stale frame 结构及 OrderIntentIdentity 可验证时，记录幂等
  StrategyIntentRejected/StaleDecision 事实；不得创建 RiskDecision、
  RiskReservation、OrderCommand 或 Order。只撤权并恢复该 StrategyInstance；
  若同时触发 input stale 或 heartbeat timeout，才升级为整 session 重建。
- 已失效 HostSession 的迟到 frame 直接拒绝，不影响新 session。
- 当前 HostSession 但旧 StrategyActivationIdentity 的排队 frame 直接拒绝，不影响
  其他策略。策略恢复/重激活获得新 activation identity。
- 当前 ring 中出现伪造 session、CRC/schema 损坏或 header/payload 身份矛盾，视为
  Host runtime/IPC 完整性失败并重建整个 session。
- 策略无权恢复时重新生成 stale intent 的同一 OrderIntentIdentity 但抑制发布，
  随后按分片日志消费 StrategyIntentRejected 事实，最终状态与连续事实轨迹一致。

fixture 必须断言 100 ms 精确边界、旧 session、新旧 activation identity、当前
session 畸形 frame 四类输入的不同处置范围，以及 StaleDecision 不进入风险/OMS。

#### AT-CHECKPOINT-DAMAGE-01：已发布 checkpoint 损坏与回退

- 恢复按 StrategyCursor 从新到旧验证已发布 checkpoint：容器长度、header/payload
  CRC、SHA-256、StrategyInstance/Definition/Config/StateSchema 身份及
  next IntentSequence 必须全部合法。
- 最新 checkpoint 缺失或损坏时记录稳定存储健康事实，并选择更早的最近有效
  checkpoint 重放更多日志；禁止修补 JSON、忽略 hash、猜字段或隐式迁移 schema。
- 没有有效 checkpoint 时，声明支持 Rebuild 且完整所需历史仍在的策略从其声明
  genesis cursor 无权重建；否则只禁用该 StrategyInstance，其他策略继续。
- 未形成 StrategyCheckpointPublished 的损坏 candidate 直接丢弃，不影响最近有效
  checkpoint。损坏内容不得传给 Host 或重新发布。

fixture 固定 checkpoint 100 有效、checkpoint 120 分别注入 header 损坏、payload
bit flip、每类截断、错误 schema 和错误 next IntentSequence，并断言：

- 系统回退到 100，重放 101..barrier；恢复期间 StrategyOutputFrame 数为零。
- 最终 StrategyStateDigest、cursor、next IntentSequence 和首个新 intent 身份
  等于“有效 checkpoint 120 + 后续重放”的对照。
- 无有效 checkpoint/历史完整得到 Rebuild 后的同一终态；历史不足得到 Disabled，
  不产生任何交易权限。

#### AT-CATCH-UP-01：持续日志上的双 barrier 激活

设 checkpoint cursor 为 C；TradingShard 在 Host 恢复期间继续正常推进分片日志。

1. Host 从 C+1 开始无权重放。接近实时头部时，TradingShard 在有序输入中插入恢复
   barrier B。
2. Host 应用至 B，回报 StrategyCursor、next IntentSequence 与
   StrategyStateDigest，但保持 Recovering 且不发布输出。
3. TradingShard 验证后，在当前 ShardSequence A 记录 HostActivated；事实携带新的
   StrategyActivationIdentity、B 和该摘要。
4. ActivateStrategy 把 A 与 activation identity 发送给 Host。Host 继续无权应用
   B+1..A；只有实际应用 ShardSequence A 的 HostActivated 事实后才进入 Active。
5. 仅 A+1 及以后事件触发、携带当前 activation identity 的 frame 才可能被核心接受。

必须断言：

- C+1..A 每个语义事件恰好应用一次，无 gap/重复，且所有 `cursor <= A` 的恢复输出为零。
- 首个可接受 StrategyOutputFrame 的 cursor 严格大于 A。
- 在线 catch-up 与离线一次性重放到 A 得到相同 StrategyStateDigest、
  next IntentSequence 和历史 OrderIntentIdentity 序列。
- 改变 IPC batch 划分不改变任何上述结果。
- Host 无法持续快于新增输入或任一 batch age 超过 50 ms 时保持无权，并以稳定
  CatchUpNotConverged 结束资格；不得暂停整个 TradingShard 掩盖性能不足。

### RunMode、实际到达与确定性重放

- 全部 RunMode 使用同一 Host 可执行入口、StrategyHostAtomicBridge、共享内存/pipe
  协议、stable codec、checkpoint 和策略代码；禁止回测直接 import/call 策略对象。
- RunMode 是 SessionPlan 的兼容字段，但不作为隐式用户策略分支开关。同一规范输入、
  配置和 checkpoint 必须产生相同 StrategyStateDigest、next IntentSequence、
  OrderIntent/IntentGroup identity 与业务 payload；session/batch/activation identity
  和真实发布时间属于运行包络，不要求相等。
- ProductionLive/ShadowSimulation 中，frame 在实际到达并通过验证时进入 TradingShard，
  依事件循环实际顺序获得 ShardSequence；该顺序写入决策日志并成为权威历史。
- SemanticReplay/故障恢复直接重放日志中已接受的 OrderIntent 或
  StrategyIntentRejected 事实；Host 的历史输出只推进策略状态，禁止重新注入核心。
- VerificationReplay 重新执行 Host，并按业务 identity、来源 cursor 和 payload 与
  历史事实比较，但只做 shadow comparison，不重新排序、风控或发送。
- L2ReplayBacktest 的机器计算耗时不推进虚拟时钟；Host 返回后按 RunManifest 的
  Python LatencyProfile 与 SeedSet 计算确定性虚拟到达时间，同一时点用稳定业务身份
  打破平局。墙钟可以等待 Host，因此只影响回测速度。
- ProductionLive、Testnet、ShadowSimulation 和生产资格 L2 回测执行 50/100 ms
  门槛；ResearchBacktest 可只报告但不能因此取得生产资格。RecoveryVerification
  永远禁止网络发送。
- 系统承诺记录后可重放和业务输出可验证，不宣称 ProductionLive 的 OS 调度或
  ShardSequence 能跨重跑相同。

### Host 内 Python 调度与策略资格

- 每个 StrategyHost 使用一个策略主事件循环线程；同一 StrategyInstance 永不并发
  调用。Host-owned 只读市场/账户视图对每个语义事件只更新一次，再按
  StrategyInstanceIdentity 升序调用已订阅策略。
- transport batch 不进入用户 API。SDK 只分发语义事件的同步回调；策略只能修改
  自己的 PortableStrategyState，并以回调返回值提出有界 OrderIntent/IntentGroup。
  用户代码不能取得 bridge/ring/pipe 或直接发布输出。
- 同一事件的输出稳定排序为 StrategyInstanceIdentity，再按各回调返回顺序。
- V1 禁止 coroutine、后台线程、子进程、跨回调任务和可写跨策略全局状态。策略决策
  时间只能来自当前事件时间戳与可重放 TimerEvent；禁止系统墙钟、系统随机源、网络
  或文件读取参与决策。
- 首版不构造 Python 安全沙箱。静态资格检查和相同输入双跑负责发现违规；违规策略
  不得上线，而核心仍对全部输出执行不可信边界验证。
- V1 不提供策略随机数 API。真实需求出现时另行增加种子和内部状态均进入 checkpoint
  的确定性 PRNG，不预建占位接口。

### StrategyHostAtomicBridge 平台 ABI

- Debian 13 x86-64 是首个生产资格平台：HostSupervisor 创建匿名 `memfd` 并仅继承
  必需 fd。Windows x86-64 开发使用匿名 File Mapping 与继承 handle，不作为首版
  生产资格平台。禁止全局共享内存名称。
- Python 从当前 ReleaseArtifact 加载唯一 Zig `.so/.dll`，使用 `ctypes.CDLL`
  的 cdecl ABI。bridge build identity 进入 HostHello 并与 SessionPlan 精确匹配。
- Python 只持有不透明 `QshHandle*`。共享 ring 的物理 layout 是同一 Zig release
  内部、带版本并在 open 时校验的实现细节，不属于稳定 Python ABI；Python 不读取
  ring header、slot 或 cursor。

V1 C ABI（C99 表示）：

```c
typedef struct QshHandle QshHandle;

typedef int32_t QshStatusV1;
enum {
    QSH_OK = 0,
    QSH_EMPTY = 1,
    QSH_FULL = 2,
    QSH_STALE = 3,
    QSH_SESSION_EXPIRED = 4,
    QSH_INVALID = 5,
    QSH_PROTOCOL_ERROR = 6,
    QSH_CLOSED = 7
};

typedef struct QshBufferV1 {
    const uint8_t *data;
    uint32_t len;
    uint32_t reserved;
} QshBufferV1;

uint32_t qsh_abi_version(void);

QshStatusV1 qsh_open_v1(
    uintptr_t input_mapping,
    uintptr_t output_mapping,
    uint64_t engine_fencing_token,
    uint32_t trading_shard_id,
    uint64_t host_generation,
    QshHandle **out_handle);

QshStatusV1 qsh_read_input_v1(
    QshHandle *handle,
    uint8_t *destination,
    uint32_t destination_capacity,
    uint32_t *out_len);

QshStatusV1 qsh_publish_many_v1(
    QshHandle *handle,
    const QshBufferV1 *frames,
    uint32_t frame_count);

void qsh_close_v1(QshHandle *handle);
```

- `qsh_abi_version()` 返回 `0x00010000`。QshBufferV1 reserved 必须为零；
  frame_count 范围 1..64。所有非 OK read 均令 `out_len == 0`。
- read 将一个已完整验证的 batch 复制到 Host runtime 预分配的 Python `bytearray`；
  用户策略只接收解码后的只读对象。publish_many 先验证全部 descriptor/frame，再
  预留、复制并一次 release-store 发布 producer cursor。
- ABI 不回调 Python、不创建 Python 对象、不使用 errno 表达协议状态、不获取进程间
  mutex。指针、长度、乘加、对齐、session 和 mapping layout 均先验证。
- qsh_close 只解除 Host 侧映射。匿名对象由 HostSupervisor 持有权威端，Host crash
  后在最后一个 fd/handle 关闭时由 OS 回收；旧 Host 无名称可重新打开新对象。

## Frozen constants and qualification parameters

实现不得自行改变的协议常量：

- 本票全部 header/record 长度、字段宽度/偏移、编码、identity、CRC/hash 和状态码；
- StrategyInputBatch 1 MiB/4096 event 上限与 `age > 50 ms` stale 边界；
- StrategyOutputFrame 256 KiB、IntentGroup 64 成员、单回调 64 frame 上限与
  `age > 100 ms` stale 边界；
- checkpoint 8 MiB、PortableStrategyStateJsonV1 深度 32，以及所有 fencing、
  幂等、失败关闭和恢复终态。

必须由后续 QualificationReport 给出证据、不得在本票猜成常量：

- 两条 ring 的实际 slot capacity/depth、control pipe buffer；
- heartbeat interval、hang timeout、kill grace；
- checkpoint cadence、catch-up lag/timeout；
- Python 精确 minor/ABI、Linux kernel/CPU 与进程 affinity；
- 代表性 batch/event/intent 速率、状态大小和 checkpoint 耗时分布；
- 每 Host 可资格化策略数。`4 Host × 约 25 策略`是首版容量验收目标，不是协议上限。

上述会话参数由 Zig 在 SessionPlan 中精确指定并写入 QualificationReport；Host 只能
接受或拒绝，不能运行时协商修改。协议/安全上限不能被资格参数放宽。

## Activity

- 2026-07-30：已认领；开始逐项冻结进程所有权、原子桥、稳定 schema 与验收轨迹。
- 2026-07-30：SystemOwner 确认 V1 采用最小 Zig C ABI 原子桥；Python 不接触共享
  指针或游标，每方向执行一次有界复制。
- 2026-07-30：SystemOwner 确认一分片一 Host；Zig 内置 HostSupervisor 独占 Host
  与共享内存生命周期，OS 仅监管 TradingEngine。
- 2026-07-31：SystemOwner 确认 Compatibility → Recovery → Activation 三阶段握手；
  Python 在 HostActivated 权威事实前没有意图权限。
- 2026-07-31：SystemOwner 确认会话身份负责 fencing，ShardSequence/StrategyCursor
  负责权威进度，StrategyInstanceIdentity/IntentSequence 负责确定性业务幂等。
- 2026-07-31：SystemOwner 确认 StrategyInputBatch 仅为传输容器；策略只观察有序
  语义事件，重放重新分批不得改变状态或意图。
- 2026-07-31：SystemOwner 确认 StrategyInputBatch v1 使用 128 字节 batch header、
  64 字节 event header、整批 CRC32C、1 MiB/4096 条协议上限和桥接前 stale 拒绝。
- 2026-07-31：SystemOwner 确认 StrategyOutputFrame v1 每帧承载一条 intent 或一个
  完整 IntentGroup，使用 128 字节 header、256 KiB/64 成员上限并在风控前重验证。
- 2026-07-31：SystemOwner 确认 IntentGroupIdentity 由实例身份与首成员序号派生，
  成员一次性占用连续 IntentSequence，不维护额外 GroupSequence。
- 2026-07-31：SystemOwner 确认单策略 checkpoint 使用受 schema 约束的规范 JSON
  子集，禁止浮点、任意映射和解释器对象，二进制编码仅在资格失败后考虑。
- 2026-07-31：SystemOwner 确认热数据使用两条 SPSC ring，控制/checkpoint 使用匿名
  pipe；checkpoint 经 192 字节容器校验并持久化成功后才发布权威引用事实。
- 2026-07-31：SystemOwner 确认 ControlFrame v1 为封闭、定向消息集；控制 pipe
  不承载交易事实或参数旁路，未知类型/方向及主循环失活均失败关闭。
- 2026-07-31：SystemOwner 确认 StrategyStateDigest v1 的 domain-separated SHA-256
  前像，并要求只有存在 expected digest 时才能声明摘要一致。
- 2026-07-31：SystemOwner 确认 AT-NORMAL-01 作为基线，覆盖 checkpoint+replay、
  显式激活、首个新 intent 与连续运行一致及重复 frame 幂等。
- 2026-07-31：SystemOwner 确认 AT-STRATEGY-EXCEPTION-01；单事件回调是提交粒度，
  失败回调的状态/输出作废，其他策略和 Host session 继续运行。
- 2026-07-31：SystemOwner 确认 AT-HOST-LOSS-01；crash/hang 均先 fencing 再回收
  整个 Host，并验证已接受/仅发布 intent 两种竞态的幂等终态。
- 2026-07-31：SystemOwner 确认 AT-INPUT-INVALID-01；输入整批预验证，超过 50 ms、
  gap、损坏或未知 schema 均零回调并重建整个 session。
- 2026-07-31：SystemOwner 确认 AT-OUTPUT-FULL-01；单回调最多 64 个 frame，经
  try_publish_many 全有或全无发布，FULL 时 cursor 不前移并重建 session。
- 2026-07-31：SystemOwner 确认增加 StrategyActivationIdentity；stale 只恢复对应
  策略并记录前风控拒绝，旧授权 frame 拒绝，当前 session 完整性错误重建整个 Host。
- 2026-07-31：SystemOwner 确认 AT-CHECKPOINT-DAMAGE-01；损坏状态不修补，按 cursor
  回退到最近有效 checkpoint，找不到时仅 Rebuild 或禁用对应策略。
- 2026-07-31：SystemOwner 确认 AT-CATCH-UP-01；恢复 barrier B 与日志内激活序号 A
  共同闭合竞态，只有应用 A 后、cursor>A 的输出才可接受。
- 2026-07-31：SystemOwner 确认全部 RunMode 共用真实 Host 协议；实盘记录实际到达，
  L2 回测使用确定性虚拟到达，VerificationReplay 只比较而不重新注入。
- 2026-07-31：SystemOwner 确认 Host 内按 StrategyInstanceIdentity 单线程同步调度，
  禁止异步/后台任务及外部非确定性输入；以资格检查而非伪安全沙箱约束 Python。
- 2026-07-31：SystemOwner 确认 Debian memfd/Windows anonymous mapping 与五操作
  最小 C ABI；Python 不观察 ring layout，输入/输出保持每方向一次有界复制。
- 2026-07-31：SystemOwner 确认协议常量与资格参数边界；全部 scope、正常/失败轨迹、
  schema、ABI、恢复终态和 RunMode 规则已冻结，本票 resolved。
