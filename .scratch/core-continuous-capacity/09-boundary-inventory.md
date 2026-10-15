# 09 当前源码边界盘点

最终补齐：冻结110份源码，身份`7d70c32ad257806e99695fa9692822373977ca2c9410695be1541afd9627fc02`。下表保留初始盘点的缺口定位；Coordinator两个计数和VenueEvidence现已为u16，Coordinator snapshot9/digest9/publish type14拒绝旧8/type1；OMS total容量及canonical/deferred追加均已使用>=的纯边界谓词。格式往返/旧格式拒绝、四真实Owner共享ceiling、四片非零经济十轮、500独立观察/三类别和四项安全背压已新增或扩充。最终运行结果见09-evidence，不用静态盘点代替。

2026-10-16，基线 `0779b48ec7a6f91e989f6d3c68049d0b012ff3dc`，独立静态盘点；并行实施中的修复以最终源码及09运行日志为准。本文件不声称下列既有测试已在本轮执行。输入合同为 issue09、capacity-contract、CONTEXT、ADR0004及0011–0016；以map最新小规模口径覆盖原容量合同中的千单验收。

所有满额/加一检查只传计数值，不填满订单、发送证据或生产数组。每个业务夹具四片合计 live≤100、terminal≤100；1024 live/片、4096 terminal/片、吞吐、千单资源和目标平台资格均未测。

| 边界 | 当前表示及实际公共路径 | 回收、失败关闭与验证入口 |
| --- | --- | --- |
| Trace | `src/trading_shard_event.zig:152`：256 Fact，len/pinned_len为usize；8192 pinned；base/last/global barrier为u64。`appendFact`先checked add序号、validate，再检查窗口；不能回绕。 | `TradingShard` checkpoint须提交有序根、保留当前authority引用再旋转；pin满返回PinnedFactCapacityExceeded。`trading_shard_tests` 的 `checkpoint maintenance carries ordered inputs and live authority through one hundred windows`、`global shard barrier continues snapshot tail replay and preserves failed append` 为公共链检查。纯边界应覆盖255/256/257及u64最大序号，不增大窗口。 |
| OMS | `src/oms.zig:4`：live1024、terminal4096、合计5120；orders/history计数u16，8项outbox计数u8；command/intent历史10240、report/reconciliation各15360。`orderCapacityReached`已实际用于createOrder。 | live或总槽满锁存capacity_pressure；独立terminal满也锁存；emit满进入RecoveryOnly。`prepare/commit archive`只释放安全终态、reservation已释放、reconciliation与Fill量闭合的完整资格。Unknown、PendingCancel和replacement引用pin。已有 `OMS order capacity guard checks numeric boundaries without order population`、`explicit archive frees repeated lifecycles without spending tombstone capacity`；公共 `order_gateway_archive_acceptance`验证真实accepted place/cancel归档、冷重复和故障恢复。 |
| ExecutionGateway | `src/execution_gateway.zig:93`：4 routes(u8)，128 origin/archive bindings(u8)，40960 dispatch accepted/uncertain各u16且合计共享上限；8192 reservations(u16)，500 exchange positions/instrument gates(u16)。`dispatchBudgetFull`与`atCapacity`已接dispatch/recovery路径。 | attempt先持久化再send；outcome提交失败保留Unknown并锁存；订单历史根提交且Owner回执匹配后才reclaim。根连续推进不释放其他命令。纯谓词已有40959/40960及accepted+unknown混合；`order_gateway_archive_acceptance`和`control_gateway_retention_acceptance`验证accepted/Unknown恢复零重发。取消仍需dispatch证据空间，满dispatch时不能声称所有撤单均可发送，应保留待发送撤单并关闭新增风险。 |
| 共享账户协调 | `src/account_coordinator.zig:15`：4 shards/leases；forced分配4、delivery16；completed forced32与GatewayOwnership32各u8。Summary open/unknown初始为u8，`shardSummaryFromShard`逐单累加。 | 各分片identity/sequence独立，reservation以gross总和约束account/global ceiling，不能以net benefit抵消。Coordinator单Writer、control stream独立；forced真实经济应用+durable ack后归档。32 route行满返回GatewayCapacityExceeded，未知仍pin。`coordinator_history_acceptance`、`coordination_gateway_acceptance`、`coordinator_safety_acceptance`为公共跨窗口路径；32项驻留路由是1024设计目标的未测限制，不因历史回收已实现就认定1024并发可用。 |
| Recovery/Cutover | `src/recovery_cutover.zig:17` VenueEvidence.orders为5120项，但初始order_count为u8，expectedVenueEvidence逐单+=1；Cutover activation8项/u8。 | 当前generation/release/schema及未完成切换保留；只回收已完成历史，恢复先撤权、需新鲜Venue证据才能Ready。VenueEvidence计数是明确可修复缺口，见下文；activation满显式ActivationHistoryFull。 |
| Adapter输出 | `src/canonical_event.zig:683`：AdapterOutputBatch32项、len u8；OrderCommandBatch4项、len u8。`append`先容量判断再写。`VenueAdapter.tryDrain`输出由Owner.applyAdapterBatch逐项应用。 | SimulatedVenue仅一个pending batch，未drain再次send返回backpressure；不能覆盖旧输出。OKX有pending_private u8及有界缓存，入队前检查空间；实际Venue容量未资格。Owner遇HistoryLookupDeferred/HistorySafetyCapacity继续已知安全事实、最终返回deferred，调用方须保留整批重试；HistoryAdmissionCapacity立即停止。纯边界应覆盖31/32/33、3/4/5，不构造32条回报。 |
| 资产及账户投影 | `asset_registry.zig`128项/u8；`instrument_registry.zig`125项/u8；`account_projection.zig`balances128/positions125/margins125(u8)，seen378(u16)。bootstrap每类至多8项/u8。 | registry容量错误不覆盖旧定义；Observation seen为近期窗口，淘汰后源序号仍拒绝过期；不能把miss当首次。投影本身valid/failure与Shard安全锁存共同决定权威性。`account observations retain a bounded duplicate window without exhausting the projection`、`core_observation_capacity_acceptance`验证观察及选择性交易；500观察是四片总量，不是单片500。 |
| 经济投影/账本 | `economics.zig:32,403`：hot fact32、ledger64各u8；各层instrument125/native asset128各u8；per-order applied fill total5120/u16；archived fill/funding/forced与ledger累计u64，金额i128。 | 完整Fill/fee/全部ledger、资金费及forced闭合资格先Store发布→Core持久提交→释放明细；唯一Fill累计不等于OMS exchange cumulative，归档不能减小总覆盖。fact/ledger满返回容量错误；Shard `latchEconomicFault`设OMS RecoveryOnly并撤权，gate槽满时仍直接trading_authorized=false。`fill_archive_acceptance`十轮partial fill、`funding_archive_acceptance`、`coordinator_history_acceptance`验证闭窗/恢复和冷冲突；32/64驻留预算不等于持续吞吐资格。 |
| 控制事实 | `operational.zig:4`：commands32、latches16、gates16各u8；Shard fence容量与当前引用独立。 | 当前authority命令、有效latch、closed gate、active operation、OMS risk refs pin；已完成记录归档后不回退version/权限/身份高水位。`control_archive_acceptance`、`control_resident_order_acceptance`覆盖跨原容量、有效风险引用、旧EnableTrading冷same不重新授权及故障恢复。无槽不能静默覆盖或借warning允许新增风险。 |
| canonical ingress/历史候选 | `trading_shard.zig:232,263,363`：16 source cursors/u8，ingress累计u64；dispatch语义证据30720/u16；risk、安全候选各1；deferred admission64/u8。 | `rememberCanonicalIngress`按stream维护高水位，same验证payload/raw digest；stream满CanonicalStreamSetFull；旧序号无认证不能新应用。候选持久保存原输入、时钟和准入结果；64满HistoryAdmissionCapacity停止批次，Owner撤权、调用方保留未处理输入。候选/暂缓证据未清即阻挡新增风险。`order_history_safety_acceptance`覆盖双槽占用、后续Fill、冲突、容量停止及恢复；pure16/17与63/64/65尚需09补充。 |
| Snapshot | `snapshot_codec.zig`header总长/payload u32，写游标usize；`durable_store.zig:28`32MiB硬上限；OMS数组编码active前缀并逐项验证encoded长度和state计数，其他policy数组仍写零尾部。 | readInto写未发布对象，验证schema/release/registry、CRC、enum/count及TradingShard内部等式后发布；不能只重算digest掩盖内部不一致。`OMS snapshot encodes active records without reserving unused terminal capacity`与`fill snapshot rejects inconsistent cumulative quantity and resident evidence`覆盖具体失效。栈、复制和32MiB实际最大编码均未资格，普通codec正确不证明资源预算。 |
| Store/manifest/index | `durable_store.zig:26`8 streams、192KiB segment、32MiB snapshot、32 active manifest entries；manifest count驻留usize、磁盘u32，segment index u32；record/byte u32，sequence/barrier u64；tail_count u8。business_history每批≤256 keys、record≤16KiB、Merkle depth≤8。 | `findStream/findManifest`扫描可用槽，无槽显式StreamCapacity/ManifestCapacity，Store外层errdefer关闭SafetyGate；checkpoint保留最近两个完整根及tail后循环reclaim active metadata。MemoryAdapter默认共享归档quota32MiB，业务历史和journal共计，不是无限盘。`checkpoint store rotates 100 rounds without cumulative manifest exhaustion`、`shared seven streams reclaim active metadata`、公共history same/conflict/proven_first及publication故障测试。纯边界应验证7/8/9与31/32/33，不填Store数组；32项活动目录不宣称4096设计预算/90天物理索引已验证。 |

## 确认缺口及处理边界

1. **Summary计数u8不容纳1024**：`account_coordinator.zig`的ShardSummary与derive局部计数在256溢出。根代理负责u16、checked sum/范围验证、snapshot8→9、digest域与publish_summary独立type升级。旧type必须显式拒绝；不能仅改字段使旧tail误解码。Coordination快照/日志有独立版本，Core/canonical未保存此DTO，不需仅为此全局升级Core格式。
2. **VenueEvidence计数u8不容纳5120**：`recovery_cutover.zig:19,101`同一问题；应该u16并以纯计数检查5120/5121，复用小订单公共恢复验证。此DTO是内存证据，不随意扩大Core持久schema。
3. **窄边界覆盖**：Trace、Adapter batch、canonical stream/deferred、Store stream/manifest须抽真实生产调用的纯谓词；每个测试覆盖last/free/full/over，不能只断言常量或伪造大数组count。
4. **容量不等于有服务余量**：GatewayOwnership32、economic hot32/ledger64、Trace256、双历史槽+64暂缓、Store32MiB默认测试盘均是有界背压来源。09可验证正确保留输入、撤权、已知安全事实继续及归档后恢复服务，不能据此证明1024并发/8192安全队列/磁盘平均成本等冻结目标。
5. **Owner批次重试责任**：applyAdapterBatch不拥有返回后的batch；返回deferred或其他错误时外围必须保留未完成原始记录，不可drain后丢弃。09小夹具应以整个批次重试验证已成功项same无副作用、尚未完成项恢复后应用，Unknown/accepted不发送。

## 本文件的证据范围

本盘点只定位当前源码、现有公共检查和需要新增的计数边界；未运行千单、填满数组、压力、真实交易、真实文件平台故障或长期保留。09最终源码身份、Debug/ReleaseSafe退出码、故障观察、RSS/栈/复制和实际record/byte计数应单独封存；不得沿用08历史测试数认定09完成。

## 09窄边界实现与开发期检查

`trading_shard_event.zig:traceCapacityReached`、`canonical_event.zig:batchCapacityReached`、`durable_store.zig:slotCapacityReached`已由真实append/目录分配路径调用，完整/超额使用`>=`拒绝。Store在原身份扫描中计used，不新增全表扫描；Trace上限取真实events数组类型长度，不另写漂移常量。无持久布局变化，无版本升级。

三个单项检查名称分别为 `09 boundary Trace guard rejects full and excess counts without populating facts`、`09 boundary Adapter batches reject full and excess counts without populating output`、`09 boundary Store directory guards reject full and excess counts without populating slots`。只传255/256/257、3/4/5、31/32/33、7/8/9及usize最大值，未伪造数组count或填满数组。

开发期先保留原`==`比较提取，`09-boundary-red.log`在Adapter/Store的capacity+1实际失败；`09-boundary-trace-red.log`在Trace257实际失败。改`>=`后，`09-boundary-green-debug.log`为main+Adapter+Store共3/3，`09-boundary-trace-green-debug.log`为Trace1/1；main直接引用Trace模块后，`09-boundary-green-releasesafe.log`收集全部3项及main共4/4，`09-boundary-trace-green-releasesafe.log`另为Trace1/1。精确命令与源码清单见相应`.result.json`；并行开发部分记录存在source_mismatches_after，只作开发期红绿证据，最终整体验收必须重新冻结源码。

统一复现入口：`python .scratch/core-continuous-capacity/run-09-command.py <name> "D:/Program Files/zig/zig.exe" test src/main.zig -O Debug --test-filter "09 boundary" --stack 67108864`，ReleaseSafe更换`-O`。64MiB为开发测试栈设置，不证明生产2MiB目标。三份修改文件的`zig fmt --check`和`git diff --check`通过。canonical ingress/deferred的纯谓词与Coordinator/VenueEvidence修复由根代理并行实施，最终以其封存结果为准。
