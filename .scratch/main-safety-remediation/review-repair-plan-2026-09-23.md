# 01–11 源码复核修复计划（2026-09-23）

Status: implementation in progress; 02/03 offline resolved, Venue absence qualification pending
Parent: [main 安全与权威状态地图](map.md)

## 边界与共同决定

- 本文记录 2026-09-23 对当前源码和 07 起点 `0d71e8e` 的复核结果。旧 `Answer`、测试计数和勾选只表示当时记录；必须按下列失败场景重新验收。修复一张票、验证一张票，再推进受其阻塞的票。
- VenueAdapter 验证私有查询证据，只向核心输出含查询范围、观察时间和证据身份的通用 Canonical 对账结果。核心不认识 OKX/Binance/Bybit 私有字段。`ConfirmedAbsent` 必须证明旧发送未形成订单且迟到成交/终态已被覆盖；证据不足保持 `Unknown`。
- Host 故障、重启或控制撤销产生可重放激活撤销；追平后使用新的 `StrategyActivationIdentity`。`TradingAuthorization` 仍由自身权威事实控制。
- 显式 Demo 路径遇 BTC/USDT 债务、保证金或额外敞口非零即失败关闭。本波不设计借币净仓模型。
- 崩溃后旧 `owner.lock`/lease 的接管须有外部可核验的隔离或 fencing；仅凭租约过期不得自动接管。离线注入不能作为真实 NodeFence 资格。
- OrderSpec 采用 exact-only：不支持的规范化/降级请求稳定拒绝，不静默削弱原生 PostOnly、VenueReduceOnly 或价格保护。06 的旧验收表述须据此纠正。
- 开发阶段不兼容旧持久流；未知或旧 schema 拒绝恢复发送。新流需显式身份和初始化，不从文件缺失推断。可删除无用兼容代码，但不自动删除磁盘上的旧数据。
- 本计划不授权 Demo/Testnet/生产写入，也不改变 production-readiness 的 Linux、NodeFence、Venue 或生产资格状态。

## 修复顺序与阻塞边

| 切片 | 票 | 完成条件 | 阻塞 |
| --- | --- | --- | --- |
| A | [02](issues/02-apply-canonical-reconciliation-to-oms.md)；[01](issues/01-fail-closed-arithmetic-and-inputs.md) 作为回归门槛 | 严格 Canonical 对账证据和真实 CCC 入口；极值与缺失输入保持失败关闭 | 无 |
| B | [03](issues/03-enforce-oms-intent-idempotency.md) → [04](issues/04-rebalance-reservation-from-authoritative-remaining.md) | OMS 幂等、冲突事实、PendingCancel/PendingAmend、保守占用 | A |
| C | [05](issues/05-preserve-dangerous-account-facts.md) | 多组合强制成交归属和持久交付 | 无；进入 07 前必须完成 |
| D | [08](issues/08-enforce-host-activation-and-ipc-isolation.md) → [06](issues/06-expand-complete-oms-dispatch-proof.md) → [09](issues/09-migrate-legacy-order-and-strategy-paths.md) | 激活撤销、真实授权引用、exact-only、稳定拒绝事实 | 06 还需 B；09 还需 B |
| E | [10](issues/10-contract-legacy-state-and-projection.md) 回归检查 → [11](issues/11-manage-order-capacity-with-tombstones.md) | 无竞争权威回流；墓碑保存每单真实意图身份 | B、D 的 09 |
| F | [07](issues/07-enforce-authoritative-gateway-send.md) | 严格 Demo 恢复、重复事实、债务、fencing 和旧流失败关闭 | A–E 中涉及的核心事实已完成；尤其 02、04–06、08、09、11 |
| G | [12](issues/12-rebuild-safety-acceptance.md) | 重新封存真实源码状态的 Debug/ReleaseSafe 证据 | 01–11 |

独立的 05、08 可作为未被前置票阻塞的 Frontier；实际认领仍遵守一次只完成一张票。01、10 本次没有确认的新缺陷，不因本计划发明修复内容，但在 A/E/G 检查其原有不变量。

## 逐项缺口与修复验收

### 02：Canonical 对账

- **R02-A，证据不足的 `ConfirmedAbsent`。** `src/canonical_event.zig` 的 ReconciliationResult 缺通用查询范围、观察时间、旧会话状态、可见性等待、终态/成交覆盖等证据；`src/trading_shard.zig` 接收状态后，`src/oms.zig` 可取消订单并释放占用。补充源端验证及稳定 Canonical 证据身份；任一条件缺失或冲突保持 `Unknown`、reservation 和 SafetyGate。用迟到报告、迟到 Fill、不同查询范围、未过可见窗口及重复/冲突证据测 live/replay。
- **R02-B，真实 Canonical 路径漏掉 CCC 后续。** `TradingShard` 的内部 OMS report/reconciliation 路径调用 `confirmPendingReplacement`，真实 Canonical report/reconciliation 路径未调用。收敛到同一订单状态转换，旧单经权威取消后必须在重新检查全局阻断、目标 revision、已成交量及授权后创建替代单；失败不能产生重叠发送或半条 predecessor 链。

### 03：意图幂等和取消阻断

- **R03-A，重复意图先经过新风险准入。** `TradingShard.handle(.oms_intent_group)` 在 `oms.groupKnown` 前重新 qualify。将持久身份/内容判断置于新风险评估前；原样重放不因当前额度、SafetyGate 或市场变化而拒绝或改写 reservation。
- **R03-B，同身份异内容没有持久冲突事实。** OMS 的 `ConflictingIntentIdentity` 错误须产生可重放、可审计的拒绝/冲突事实，且不得提交订单、命令或占用。验证崩溃后同一冲突结果。
- **R03-C，部分成交覆盖 `PendingCancel`。** `Oms.applyReportInPlace` 将其改成 `partially_filled`，而 `blocksNewSend` 不再阻断。保留 cancel 待确认语义及后续成交数量；在取消权威结案前 place/amend/CCC 均不能越过全局阻断。

### 04：PendingAmend 期间的占用

- **R04-A，部分成交提前释放新订单所需额度。** `Oms.applyReportInPlace` 将 `PendingAmend` 覆盖为 `partially_filled`，`rebalanceReservation` 只按旧 confirmed reservation 计算；随后 amend reject 可能把仍 live 的旧单视作整单 rejected。OMS 必须在 pending amend 全程保留旧/新最坏剩余占用上界；成交更新旧单累计量但不抹掉 pending amend；amend reject 只撤销修改请求。测试部分成交→amend 成功、拒绝、Unknown、重复报告、快照和 replay。

### 05：强制成交经济归属

- **R05-A，单 owner 直投且缺经济维度。** `AccountFactPayload.forced_execution` 与 `ForcedExecutionAllocation` 只支持一个 owner；`acceptAccountFact` 信任调用方 owner，`accountFactEvent` 丢失 penalty。强制成交先进入不猜归属的 Suspense；经证据验证后，使用有界多组合切片分配数量、PnL、费用、罚金及仓位变化，逐项守恒，允许相反方向和部分归属。来源事实不可被后续分配改写。
- **R05-B，分配交付不可恢复。** `allocateForcedExecution` 只记最后一次 allocation，重试又依赖可能被新账户事实覆盖的 `last_account_fact`。持久记录 allocation 身份、每个目标切片和交付进度；崩溃于分配提交与 shard Delivery 之间、插入其他账户事实后重试，都必须确定性补投且不重复入账。

### 06：DispatchProof 和订单语义

- **R06-A，TradingAuthorization 引用错误。** `TradingShard.dispatchAuthorityRefs` 使用最后一条 control command；`CancelOpenOrders` 不授予或撤销交易权。proof 必须引用实际生效的授予/撤销事实身份及 barrier；验证 EnableTrading→CancelOpenOrders 后引用仍准确，并证明 Gateway 的当前授权复核不被旧 proof 绕过。
- **R06-B，旧票宣称的规范化/降级结果并不存在。** OMS Intent/Command 没有这类策略和结果字段。本波只接受精确 OrderSpec，无法原样表达/执行的请求给稳定、可重放的拒绝；06 的文档与验收改为 exact-only，不添加投机性降级框架。

### 07：唯一 Gateway 与 Linux Demo 恢复

- **R07-A，起点提交 `0d71e8e` 缺订单级恢复对账。** 当时仅账户对账就调用 Gateway 结案，而结案需要新鲜订单 reconciliation。恢复必须从持久 ingress 获取每个 Unknown dispatch 的权威订单证据，未结案期间不重发。
- **R07-B，当前 Demo 将未证实的 absent 升级成已确认。** `okx_demo_live_acceptance.zig` 无条件设置 `visibility_delay_elapsed`、`prior_session_inactive`，`okx_venue_adapter.zig` 随后可输出 `confirmed_absent`。删除调用方自报的证明位；由 VenueAdapter 验证 R02-A 的证据。缺项保持 Unknown，不能释放 reservation 或重新发送。
- **R07-C，重复 Canonical 事实永久关闭 Owner。** `TradingShard.rememberCanonicalIngress` 对合法重复 report/fill 返回 no-op，而 `demo_authority.Owner.apply` 把任何零 journal 增量当成错误。区分已验证重复 no-op 与输入未产生事实/持久提交失败；重复不关闭 Owner，冲突与持久失败仍关闭。以 report/fill 的真实重复 ingress 测试。
- **R07-D，崩溃留下 `owner.lock` 后没有可证明接管路径。** `LinuxFencingStore.open` 会留下锁文件，旧 token 又阻止直接 acquire。制定外部隔离/fencing 后的操作员恢复协议；离线验证旧 owner、旧 token 和新 owner 并发时无双主，真实目标 NodeFence 资格仍留 production-readiness。
- **R07-E，Demo 零仓启动漏债务/额外敞口。** 当前 bootstrap 只覆盖部分 BTC/USDT 余额，净仓计算忽略负债。显式 Demo 路径检查 BTC/USDT 债务、保证金及其他敞口，任一非零失败关闭；该问题是条件性业务风险，不能在未核实 Venue 字段语义前声称已线上触发。
- **R07-F，旧流与新流边界。** 删除无用旧 schema 兼容路径；旧/未知 schema、缺失或不匹配的决策/dispatch 流身份一律失败关闭。显式新流初始化不得把旧文件当空流，也不得自动清除旧数据。提交后崩溃的 dispatch 恢复 Unknown、对账结案后不重发。

### 08：Host 激活生命周期

- **R08-A，旧激活身份在故障后仍有效。** `TradingShard.host_activation_identity` 只设置一次，host fault/control pause/restart 未撤销；`submitOrderIntent` 仍接受旧身份。加入可重放撤销事实，故障或新 session 立即失效旧身份；追平和重新验证后才以新身份激活。direct trade 与 recovery、旧 session 和 replay 同测，TradingAuthorization 独立核验。

### 09：稳定拒绝事实

- **R09-A，真实入口直接返回错误。** `submitOrderIntent` 对未激活、身份不匹配、仍有 open order 直接抛错，`applyStable` 未记录普通拒绝；RejectReason 也缺身份冲突/能力类。经真实提交入口生成区分未授权、市场 gap、五层限额、opening gate、身份冲突、能力缺失及 open-order 阻断的稳定事实；无订单或发送副作用，重复与 replay 一致。

### 11：墓碑身份

- **R11-A，墓碑使用组首序号。** `Oms.createOrder` 存 `group_first_sequence`，`compactOne` 以此填写 Tombstone.intent_sequence；多成员组第二单及 CCC replacement 的真实序号因此丢失。为每张订单保存自身来源 `OrderIntentIdentity`，保持 group 身份另存；验证压缩前后重复/冲突意图、predecessor、迟到报告与摘要一致。

### 01、10 和 12：回归与重新封存

- **01、10：** 本次没有确认的新缺陷。仍验证极值/缺失事实拒绝不提交状态，以及没有 legacy 订单、风险、经济权威或业务 raw send 回流。
- **R12-A，源码身份不准确。** `tools/verify-core-wave.ps1` 在脏工作树只把 `HEAD` 记录为 source revision。验收需绑定实际被测内容（例如 clean revision 或包括工作树内容的可复核身份），否则不得标为封存通过。
- **R12-B，旧 schema/计数陈述过期。** 12 票和 map 仍写 state schema 15、Debug/ReleaseSafe 239/239；当前源码 state schema 为 16，既有计数不能证明本次缺口已关闭。所有修复完成后重新运行同一矩阵，记录实际 schema、精确 Zig、测试数、barrier、digest、Gateway send count 和失败事实；离线通过不升级线上资格。

## 关闭规则

每票的 `Answer` 追加本轮源码位置、提交或可复核工作树身份、最小失败用例、修复后 Debug/ReleaseSafe 与 live/replay 证据；只有对应未勾选条件全部有证据才恢复 `resolved`。12 最后更新 map、审查文档与 production-readiness blocker。当前不进行源码修复、测试封存或任何 Venue 写入。
