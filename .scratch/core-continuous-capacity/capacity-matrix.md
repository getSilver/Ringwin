# 持续运行容量矩阵（当前源码盘点）

关联：[票 01](issues/01-freeze-capacity-and-retention-contract.md)、[模块地图](map.md)。
日期：2026-10-09。源码基线：`9f47ae6f`；任务导入提交：`3d130d1b`。本文件是合同输入，不是实施或资格证据；所有目标回收路径仍待后续票实现。

盘点按当前源码的数组、计数器、所有写入/耗尽点与现有恢复 seam 核对；不沿用旧地图关闭结论。已读取根级 CONTEXT、ADR 0004/0006/0009。以下路径相对于仓库根，行号对应上述基线。数值为**现有实现**，不是建议预算；目标速率、保留期与资源预算由同目录合同规定。

分类：**当前**是仍有业务效力的状态；**积压**是尚未完成持久归档/对账的对象；**历史**是随累计业务增长的身份或证据；**传输**是可消费的暂态有界队列。只有传输出队与显式当前状态替换可直接释放；历史不能通过清空数组或重置序号释放。

## 核心、OMS、经济与配置

| 对象/类别 | 当前源码容量和计数 | 耗尽与现有回收 | 历史/恢复缺口；目标所有者与后续票 |
|---|---|---|---|
| Trace / 历史 | `src/trading_shard_event.zig:95-110`：256 Fact；len 为 usize，Fact.sequence 由 len+1 得出 | append 返回 TraceFull；没有回收 | `src/trading_shard.zig:448-484` 快照要求 trace.len=barrier=journal.last_sequence；Trace 在 CanonicalStateDigest 中，不能重置。TradingShard 持有全局屏障与摘要承接，Owner/DurableStore 持有完整历史；02/03 |
| StrategySuccessor fence / 历史 | `src/trading_shard.zig:249-250,2341`：8 个 u128，u8 count | 新身份超限 StrategyFenceCapacityExceeded；不移除 | 旧实例失权证据不能随发布次数耗尽。TradingShard 保留当前授权，历史失权身份走可验证查证输入；08 |
| canonical ingress cursor / 当前流集合 | `src/trading_shard.zig:162,262-263,1820-1879`：16 stream cursor，u8 count；count/digest 为 u64/SHA256 | 同 stream 更新最近身份；新 stream 超限 CanonicalStreamSetFull；旧序号返回 StaleCanonicalIdentity；历史语义重复依赖各投影 | 当前 cursor 不含全历史冲突证明；会话/stream 不断新增仍耗尽。Adapter 负责源身份，核心接收可验证退休/查证结果；02/03/05-08 |
| OMS 热订单 / 当前+积压 | `src/oms.zig:4,235-236`：8，u8 order_count | 创建时 compactOne；无合格终态则 OrderCapacityExceeded；Unknown/PendingCancel 不合格 | 目标每分片 **1,024 存活订单**，待归档终态另设预算；u8 不能表示目标。OMS 拥有存活状态与唯一填单累计关联；05/09 |
| OMS tombstone / 历史 | `src/oms.zig:10,247-248,1014-1069`：2，u8 count | compactOne 不驱逐墓碑；满返回 TombstoneCapacityExceeded，并经 applyGroup 容量路径保留 RecoveryOnly | 终态填满第二层后停机。需外部持久历史身份索引和核心可重放归档确认；05 |
| OMS 归档资格 / 积压 | `src/oms.zig:1054-1069,1797-1815`：filled/canceled/rejected，零活动 reservation，无 replacement、无被热单 predecessor 引用；archive_window_closed 与非零 audit digest | qualification 要最后 reconciliation 证据，digest 冲突 RecoveryOnly；pressure 时只搬一个合格热单到墓碑 | 当前 archive_window_closed 是源码证据资格位，**不是按时间保留合同**；墓碑保留 last report/reconciliation、身份、client id 和 fact digest，无外部归档删除 seam；05 |
| OMS 本次 commands / 传输 | `src/oms.zig:6,237-238,253-255,915-924`：8，u8 count；group 成员4 (`:5`) | begin 清本次 outbox；emit 满 CommandCapacityExceeded 且 RecoveryOnly | 千单 KillSwitch/撤单不能受一次8项出队限制；保留安全撤单分批推进与重放身份；05/09 |
| OMS command_history / 历史 | `src/oms.zig:7,239-240,915-924`：32，u8 count | emit 满 CommandCapacityExceeded、RecoveryOnly；不随 outbox begin 回收 | 所有 place/cancel/amend 共用累计历史；OMS/Gateway 联合归档发送证据，查证不得重发；05 |
| OMS intent_history / 历史 | `src/oms.zig:9,245-246,367-381,410-421`：64，u8 count | 包含拒绝组；IdentitySetFull、RecoveryOnly；duplicate 无副作用/conflict 拒绝；无回收 | 原始 intent fingerprint/group policy 必须跨归档保留。策略身份序列与历史查证归属 OMS；05/08 |
| OMS report_history / 历史 | `src/oms.zig:8,241-242,540-566`：32，u8 count | IdentitySetFull、RecoveryOnly；重复先比内容；墓碑外晚到事实可能 TombstoneFactConflict/ArchivedFactOutsideRetention | 不能仅保留终态最后 report 而丢历史身份冲突；05 |
| OMS reconciliation_history / 历史 | `src/oms.zig:8,243-244,731-774`：32，u8 count | IdentitySetFull、RecoveryOnly；无回收 | 归档须保留范围、revision、覆盖与缺失证明；05/07 |
| 经济 seen / 历史 | `src/economics.zig:29,206-207,765-773`：32，u8 count，共用于成交、费用相关经济事实、资金费、强制执行、transfer、snapshot身份 | EconomicFactCapacityExceeded；事务候选提交；公共 canonical fill/funding 故障走 shard 经济锁存 (`src/trading_shard.zig:314-338`) | balance/PnL 投影不能代替唯一 applied fact 身份；同 identity 同内容幂等、冲突关闭风险；Projection 持当前余额，外部历史查证输入保持幂等；06/07 |
| canonical_fill_evidence / 历史 | `src/economics.zig:208-209,281-298`：32，u8 count，canonical payload digest/order/fill evidence | EconomicFactCapacityExceeded；不回收 | canonicalFilledQuantity 必须独立于 OMS exchange-reported cumulative_quantity；归档按 order 保留唯一 applied-fill 累计与身份链，迟到 fill 仍受 overfill 检查；06 |
| ledger / 历史 | `src/economics.zig:30,210-211,779-824`：64 transaction，u8 count；每笔最多4 posting (`:39,90`) | LedgerCapacityExceeded；一事实可产生多笔 transaction，不能按事实数等比预算；无回收 | 当前 native balance/成本/PnL 与账本链起点随 checkpoint 承接，完整 posting 历史在 DurableStore；07 |
| reconciliation break identities / 历史 | `src/economics.zig:204-205,832`：32，u8 count | ReconciliationBreakCapacityExceeded；无回收 | 已解决 break 仍为历史，不能删除未解原因或重新授权依据；07/08 |
| native asset 当前投影 | `src/economics.zig:46,55-56,79,192-195`：每个 EconomicState、Treasury/Suspense 最多8 asset，u8 count | NativeAssetCapacityExceeded；余额归零不自动删除 | 不与历史条数混同；有 open order/ledger/config/reference 不可退休；资产注册表与经济投影共同证明引用释放；04/07 |
| AssetRegistry / 当前版本集合 | `src/canonical_event.zig:151-152`：8 asset definition，每项4 Venue code binding；`src/asset_registry.zig:32` | AssetRegistryFull；现有 key 更新校验，不提供引用安全退休 | 各 Venue 资产编码和历史 scale/version 必须可恢复，目标覆盖实际选择资产；04 |
| InstrumentRegistry / 当前版本集合 | `src/instrument_registry.zig:8,83`：4 entry，u8 count | InstrumentRegistryFull；按 identity upsert，无历史生命周期 | 500观察组合不等于500活跃订单 instrument；rules/version 映射须覆盖观察组合及历史引用。Registry 当前热集，版本证据外部持久化；04 |
| MarketProjection / 当前观察 | `src/market_projection.zig:6,115`：4 instrument，u8 count | MarketInstrumentCapacityExceeded；失败状态/generation 保留，无通用退休 | 目标覆盖约500 Venue×产品×交易对观察，当前 scalar active-instrument view 不能代表完整多品种经济持仓；04 |
| AccountProjection / 当前+近期观察 | `src/account_projection.zig:17-24`：balances/positions/margins/seen 各8，u8 count | 当前 key 更新，显式 removed 删除 (`:115-151`)；新 key 满 ObservationCapacityExceeded 并 invalidate；seen 满滚动移位 (`:79-101`)，bootstrap 替换当前状态 | seen 为近期窗口，不是无限历史幂等证明；source_sequence/bootstrap 连续性必须保留；更旧经济/订单身份依赖完整历史。04/07 |

## Gateway、控制、账户协调与 Host

| 对象/类别 | 当前源码容量和计数 | 耗尽与现有回收 | 历史/恢复缺口；目标所有者与后续票 |
|---|---|---|---|
| Gateway route/current account authority | `src/execution_gateway.zig:67,115-120,294-298`：4账户 route，u8 count；每 route 最新 authority | RouteCapacity；没有 route 退休；重复 account 拒绝 | 4 route 是账户维度，不自动等于4 Venue所有账户/产品组合；目标路由覆盖由合同固定。Gateway 维护当前发送准入；04/09 |
| Gateway instrument gate / 当前 | `src/execution_gateway.zig:117-119,748-760`：4，u8 count | 相同 instrument 更新；新 key 满设 instrument_gate_capacity_exhausted，后续全部 instrument 开单受阻 | 需与500观察/选择交易区分；已退休 instrument 的 gate 必须经过引用与当前安全状态确认；04/08 |
| Gateway reservation / 当前身份累计 | `src/execution_gateway.zig:69,121-124,324-356`：max_routes×oms.max_commands=32 reservation，32 position key，各u8 count | AuthorityCapacity；同 reservation id / account-instrument 更新，零占用不会回收 | 仅把 oms.max_orders 扩到1024仍不改32限制；当前未完成 proof 的 reservation 不可删，已闭合身份转历史；05/09 |
| Gateway accepted dispatch / 历史 | `src/execution_gateway.zig:125-126,357-373`：32，u8 count | DispatchCapacity；相同完整 proof 幂等返回；无删除 | proof、client id、command identity 和发送结论需要持久幂等查证；05 |
| Gateway uncertain dispatch / 当前+历史 | `src/execution_gateway.zig:127-128,165-220,379-385`：32，u8 count | markUncertain DispatchCapacity；sendFromShard 满直接 NotSent；对账完成仅更新记录，不删除 | durable replay 将已提交 attempt 恢复为 Unknown，不重演 send；resolution仍占槽。归档必须有权威对账闭合，并保留历史“不重发”证明；05 |
| Operational control history / 历史 | `src/operational.zig:4,98-99,138-143,191`：32 command，u8 count | ControlCommandHistoryFull；重复先比完整命令；无回收 | 安全命令也共享累计上限，满可能无法接收新的停止命令；当前 version/authority 与完整历史身份分离，外部查证必须可重放；08/09 |
| Operational gates / 当前身份集合 | `src/operational.zig:6,96-97,217-225`：16 gate，u8 count | 同 id 更新，新 id SafetyGateSetFull；无删除；shard 特定安全路径会撤销 trading_authorized (`src/trading_shard.zig:1819`) | opened gate 仍占位置；按错误事件新身份创建会累计。当前 scope安全合取不能随回收弱化；08 |
| Operational latch history / 当前+历史 | `src/operational.zig:5,100-101,183-185,313-317`：16，u8 count | LatchHistoryFull；resolve仅置 resolved，不移除 | 未解决 latch 必须常驻；已解决 id/reason/人工重新授权证据转历史，不清空；08 |
| Lifecycle 当前 operation | `src/operational.zig:87-113,165,264-274`：单目标一个 active operation | LifecycleOperationConflict；显式完成后释放 | 不需无限队列；跨范围阻塞和KillSwitch例外仍保留；08/09 |
| AccountCoordinator 当前 summary/lease/delivery | `src/account_coordinator.zig:12,496-505`：4 shard，summary/lease/account delivery/gate delivery各4 | 同 shard/最新 barrier替换，不是累计历史 | shard summary 的 open_orders/unknown_orders 为u8 (`:40-41,337-342`)，1024计数溢出；Unknown与其他风险订单必须宽计数且不能把Unknown排除活单目标。四分片全局一致屏障由coordinator承担；02/08/09 |
| AccountCoordinator suspense forced source / 积压 | `src/account_coordinator.zig:506-517,687-737`：单个待分配 forced_execution source | 新强制执行遇未清 suspense返回 SuspenseAccountCapacityExceeded；闭合/分配后继续，期间RecoveryOnly且lease占满 | 不能用覆盖源事实吸收峰值；当前残余、source position、allocation/ack 必须耐崩溃保留；07/08 |
| AccountCoordinator forced allocations / 当前+历史 | `src/account_coordinator.zig:13,512-517,704-722,761`：当前4 allocation；完成历史32；delivery缓存16，u8计数 | 当前满 ForcedExecutionAllocationCapacityExceeded；下一源接入将旧allocation搬完成历史；总预算检查超过32返回 ForcedExecutionHistoryCapacityExceeded；无历史回收 | 包括source身份、切片归属、delivered mask、跨shard ack；摘要/快照/coordination tail已存在 (`:1096-1200`)，但无持续历史归档；08 |
| 账户协调旧 Gateway dispatch record / 历史 | `src/account_coordinator.zig:397-415`：32 GatewayRecord，u8 count | GatewayCapacityExceeded；complete不移除身份记录 | 与execution_gateway为不同结构，不能漏盘点。保持shard/fencing/command routing幂等，联动历史归档；05/08 |
| CoordinationJournal / 历史载体 | `src/account_coordinator.zig:162-197`：内嵌journal.Journal，即192KiB | JournalFull；没有通用协调日志checkpoint轮转运行闭环 | Coordinator snapshot/tail恢复已有，需与四分片共同checkpoint/确认屏障、档案依赖闭合；03/08 |
| StrategyHost Gateway published batch / 会话历史 | `src/strategy_host_gateway.zig:11,139-140,191,298-310`：64 published，usize count | 满 InvalidPublishedBatch；会话切换清 published；普通batch无回收 | 不是核心权威日志但同会话持续64 batch即阻塞；以ack/cursor/freshness引用保护退休，保留session连续性；02/09 |
| StrategyHost Gateway seen intent / 会话历史 | `src/strategy_host_gateway.zig:12,141-142,328-350`：64，usize count | 满返回 rejected malformed；无按业务闭合回收 | 会话局部校验不能替代OMS跨会话业务身份；退休仍须业务查证，不能重新接收重复；05/08/09 |
| Cutover activation history / 历史 | `src/recovery_cutover.zig:307-308,477`：8 activation，u8 count | 重放满 ActivationHistoryFull；无回收 | 发布/回滚历史与当前策略归属分离；旧实例fence同步归档；08 |
| FencingAuthority domain / 当前 | `src/failover.zig:24,105-106,183`：8 domain | AuthorityCapacity；已有key续租更新，无域退休 | 代次永久不复用，退休域后旧token/NodeFence历史仍需保留；08 |
| FailoverReport / 单报告积压 | `src/failover.zig:25,770-778`：32 AdmissionEvidence | ReportFull；不静默丢失败事实 | 每个report独立封存并由RetentionPolicy引用保护，不将32视为系统终身报告数；08 |
| Runtime control queue / 传输 | `src/production_runtime.zig:9`、`src/windows_verification_runtime.zig:77`：8 | 有界运行队列，不等于32控制幂等历史 | 安全命令优先/保留余量与下游历史耗尽均须验收；08/09 |

## Canonical seam 与 VenueAdapter

| 对象/类别 | 当前源码容量和计数 | 耗尽与现有回收 | 历史/恢复缺口；目标所有者与后续票 |
|---|---|---|---|
| Canonical request/output batch / 传输 | `src/canonical_event.zig:301,413,674`：4 order command/32 event；account scope payload每类8；`src/canonical_event_codec.zig:12` 编码最多4096字节 | 调用方/Adapter按batch限制拒绝或分批；消费释放 | item数量满足不保证4096字节编码可容纳；layout必须验证最坏非空字符串/decimal/evidence集合；03/09 |
| VenueConfig request/output limits / 传输 | `src/venue_adapter.zig:1-28`：调用方指定，不代表内部所有数组随config增长 | Adapter open校验；具体实现仍受下列硬上限 | 按route报告有效minimum容量；只改config不等于协议支持；04/09 |
| OKX order Scheduler / 传输 | `src/okx_order_entry.zig:18-21,241-245,327-331`：normal64/safety32，batch20，请求16KiB | enqueue Full/背压；poll出队；安全队列独立 | 千单撤单需有界分批，不能一次塞入1024；Adapter拥有Venue限流/优先级，核心不私自翻译；09 |
| OKX pending commands/order links | `src/okx_venue_adapter.zig:55,98-105,1234-1267`：pending96、order_links96，u8 count | pending完成移除；link相同id验证后复用，新idFull，**没有终态link回收** | link是持续累计瓶颈；订单revision/client id和私有facts映射需归档与重建；05 |
| OKX ready private/output / 传输 | `src/okx_venue_adapter.zig:94-97,510`：private128 (u8 count)，单pending_output | private消费移位减count；溢出/私有故障关闭路径，不覆盖 | pending所有权始终在Adapter，通过ingestPrivateWs→tryDrain进入核心；恢复先重放durable raw，再授权；03/09 |
| OKX reconciliation requests / 积压 | `src/okx_venue_adapter.zig:56,105-110,539,567`：8 order请求、单account请求 | 完成后清本轮count；有界拒绝 | Unknown目标规模不可依赖一次8个完成；分轮推进，保留每个订单覆盖证明；05/09 |
| OKX经济请求证据 / 本轮积压 | `src/okx_venue_adapter.zig:111-120,419-420,583,735,915,990`：bill16/query4/known fill32/balance-source8 | bills/query每轮reset；known fills满NativeAssetCapacityExceeded、不回收；asset source满同错误；balance-source按key更新时间 | “NativeAssetCapacityExceeded”在此也可能是事实容量，不是资产数量；known fills依赖唯一成交与bill覆盖，外部归档须保留可验证覆盖；06/07 |
| OKX私有reconciler身份 / 历史 | `src/okx_private_reconciliation.zig:23,359-360,1174-1181`：seen512，usize count | 满BufferFull；duplicate比identity/content；普通reconcile/disconnect不清seen (`:380-400`) | 不得以reconnect掩盖历史身份；Adapter接收归档查证并输出canonical可重放事实；05-07 |
| OKX私有reconciler缓冲 / 传输+bootstrap积压 | `src/okx_private_reconciliation.zig:19-22,270,361-364,682-689`：page20，单ingress40，bootstrap160，WS128；账户balance/position各8 (`:114,136`) | BufferFull；reconciliation/disconnect清bootstrap/WS暂态，drain推进索引 | 合并分页/WS峰值需留独立余量，不能清尚未canonical应用的durable事实；03/09 |
| Binance私有reconciler / 历史+当前+传输 | `src/binance_private_reconciliation.zig:21-24,51-66,130,462-482,525-541`：seen128/link32/buffer96/ready96/pending observation24；balance/position/margin各8 | FactCapacity/OrderLinkCapacity/PrivateBufferFull/PrivateOutputFull/AccountFactCapacity；drain清ready；beginSession重建所有状态 (`:99-103`)，sourceGap废弃未完整bootstrap并offline | link/seen在同session无回收；重建session必须durable raw replay+完整bootstrap，不可视为合法删除历史；03/05-07/09 |
| Bybit私有reconciler / 历史+当前+传输 | `src/bybit_private_reconciliation.zig:34-36,56-69,101,346-359,405-421`：seen128/link32/buffer96/ready96；balance/position/margin各8 | FactCapacity/OrderLinkCapacity/PrivateOutputFull/AccountFactCapacity；ready/drain释放；同session历史无回收 | 归档身份查证、私有事实映射和bootstrap连续性仍由Adapter负责；03/05-07/09 |
| Binance/Bybit Unknown registry / 当前 | `src/binance_venue_adapter.zig:75,101-102,360-375`；`src/bybit_venue_adapter.zig:66,90-91,316-331`：各32，u8 count | markUnknown满置unknown_overflow；已证明订单clearUnknown减count；overflow不会凭单次清除自动恢复 | 需要覆盖1024潜在未闭合订单的目标与独立对账余量；未知必须从durable dispatch/raw恢复，不自动重发；05/09 |
| Binance/Bybit adapter pending output / 传输 | `src/binance_venue_adapter.zig:90-103`、`src/bybit_venue_adapter.zig:79-92`：各单batch；request/output config与canonical batch限制共同约束 | 未drain则背压；drain释放 | 不增加第四家协议，四家接入目标是路由/账户预算；03/04/09 |
| 私有原始恢复输入索引 / 恢复积压 | `src/okx_private_recovery.zig:16,63-67,109`：max_inputs1024/visited1024/stream16，usize计数 | 输入或stream超限 PrivateRecoveryCapacity，不能截断证据 | 恢复时限不能以只读最近1024而丢已提交事实达成；需流式分段恢复/查证，核心不做I/O；03/10/11 |

## 存储、快照与布局约束

| 对象/类别 | 当前源码容量和计数 | 耗尽与现有回收 | 历史/恢复缺口；目标所有者与后续票 |
|---|---|---|---|
| Journal / 当前segment | `src/journal.zig:7-12,55-63,108-139`：192KiB；header64/record header72/footer32；payload4096；records u64/sequence u64 | JournalFull/PayloadTooLarge；seal留footer；initAt承接sequence，但调用方必须持久闭合旧段 | 全局屏障不可退回局部Trace；单事件可生成多Fact和input journal record，预算按实际编码；02/03 |
| RawIngress DurableSink / 当前segment+历史 | `src/raw_ingress.zig:14-16,45-85`：frame最大4096−72=**4024B**；原始header72 | 大frame Unavailable；segment不足时seal→8字节checkpoint→rotate，要求segment replay；每record commit | public parser允许1MiB不代表durable raw可接受1MiB；须显式冻结大frame分片/封存策略。原始历史仍受manifest32项限制；03/09 |
| DurableStore stream registry / 当前 | `src/durable_store.zig:13,210-219,250,410`：8 stream (domain+id)，Memory/File共用 | StreamCapacity；append/文件操作错误关闭store safetyGate；无stream退休 | 4 decision+raw+gateway/control+coordinator可超过8；实例/stream拓扑需逐项预算，不以4 shard推断足够；03/08 |
| DurableStore manifest / 历史segment元数据 | `src/durable_store.zig:16,220-227,254,414`：32项，跨本store所有stream累计 | ManifestCapacity，持久化失败关闭gate；rotate不移除旧项 | 可容纳的轮转次数取决共享stream数；现无RetentionPolicy/delete/index/checkpoint回收API。需分代manifest/保留引用和连续承接证明；03 |
| DurableStore snapshot / 当前定位点 | `src/durable_store.zig:15,251-253,411-413,606-654`：每stream64KiB，单槽当前snapshot | SnapshotTooLarge关闭gate；barrier必须sealed last_sequence；文件临时写/sync/rename/目录sync；新snapshot替换当前 | 改到1024 order不意味着64KiB足够；必须测snapshot_codec最坏编码。旧snapshot可用于恢复/回滚引用时不能仅靠单槽覆盖；03/10/11 |
| DurableStore segment rotation / 持久屏障 | `src/durable_store.zig:333-348,581-604`：segment_index u32 | 必须sealed且snapshot覆盖精确last_sequence，否则关闭gate；新段initAt(last+1) | current file adapter有分段replay，MemoryAdapter不提供全部旧段文件；不能将memory rotate等同完整历史恢复；03/10/11 |
| 业务Owner checkpoint / 运行闭环 | `src/demo_authority.zig:390-421`：sealBootstrap只允许尚未ready时调用；committedSnapshot (`:427-432`)只生成读取副本 | bootstrap一次seal/publish/rotate；运行中无通用周期checkpoint+历史归档闭环 | 不能仅证明底层rotate存在；要业务Owner协调停止/持久barrier/跨shard引用/重启恢复；03/08 |
| State codec/schema / 恢复身份 | `src/production_contract.zig:11-15`：journal30/state34/registry28；`src/trading_shard.zig:448-484` 严格快照元数据和digest检查 | 不匹配/摘要或barrier冲突失败关闭；不是ADR0006旧schema9 | 计数宽度、容器布局、barrier与archive root变化需明确schema演进。ADR0009当前要求完整Trace/ingress在CanonicalStateDigest，必须先修订连续承接语义，SemanticAuthorityDigest不得用于恢复；01/02/03 |

## 统一回收与查证边界（目标要求，当前未实施）

每类历史迁出热内存前都必须有同一权威屏障上的持久归档确认：对象/内容身份、覆盖范围、当前投影摘要、归档根、版本、引用保护和删除条件。未闭合风险、未应用canonical事实、未确认跨shard delivery/ack、仍被order predecessor/lease/latch/config/checkpoint/recovery引用的对象不得回收。关闭新增风险不能阻止已有raw事实持久化、撤单、回报和对账完成；这些路径的独立余量在负载合同与票09验证。

历史I/O归Owner/Adapter/DurableStore，核心仅接收绑定请求身份、归档根、覆盖范围、内容摘要与schema的可验证、可重放输入。查证必须区分相同历史事实、冲突、证明未存在和证据不可用；不可用维持RecoveryOnly，不能把“没在热数组找到”当成fresh/absent。Unknown dispatch绝不因清槽自动重发。

四分片checkpoint必须记录各shard全局屏障、账户协调屏障和相互引用的delivery/ack/dispatch/raw范围，不能以四个不同时间的本地快照拼出完整恢复。摘要承接记录保留完整历史Trace与canonical ingress顺序的承诺及当前权威状态，具体格式由02/03实现，ADR0009修订及schema变更在实现前明确。

布局验证至少打印四种负载状态的`@sizeOf/@alignOf(TradingShard/Oms/Projection/Gateway/AccountCoordinator)`、字段offset/count类型、1024活单+终态积压、取消突发、最坏完整snapshot实际编码字节；分别计数apply候选复制、snapshot canonicalize复制、committedSnapshot传递复制和恢复工作区。u8容量/循环/summary/dispatch batch计数逐个核对，不能全局机械改宽。当前源码已按值复制完整TradingShard (`src/trading_shard.zig:289,372,448-460`)，扩数组同时扩大每事件复制成本；合同冻结预算，后续按测量验证，不在本票预先重写架构。

Windows与Linux各自记录OS/文件系统/硬件/构建schema、种子/负载、目录文件清单、segment/manifest/snapshot摘要与barrier、崩溃点、恢复状态与最终CanonicalStateDigest、缺段/满盘/损坏/保留引用结果。文件验收与真实性能/断电资格分开；跨平台复用业务输入，不共享平台通过结论。完整预算和可复现入口由[容量合同](capacity-contract.md)承接；合同与矩阵均不代表实现完成。
