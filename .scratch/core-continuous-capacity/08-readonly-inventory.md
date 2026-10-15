# 08 控制与账户协调历史只读清点

Status: preparation-only; no implementation or acceptance

2026-10-13，GPT 6.1 Sol / medium核对05冻结源码身份 `ea80a6aef916f2b9c9390cda2c4265e1a0e58456d2e5c156908117d7f6d7009a`。05完整验收仍在执行，本记录不认领08、不修改业务源码、不关闭任何票；实施时重新核对06/07后的实际接口。

## 必须分别闭合的累计状态

| 范围 | 当前源码 | 可回收条件 | 必须保留 |
| --- | --- | --- | --- |
| Operational command，32项 | `src/operational.zig:98–101,131–194` | 已完成且无引用 | active operation、当前授权、未闭合撤单/风险引用 |
| gate/latch，各16项 | `src/operational.zig:212–255,285–318` | 明确退役的opened gate、已解决且无引用的latch | closed gate、未解决latch、连续性损失及人工授权要求 |
| strategy fence，8项 | `src/trading_shard.zig:293–294,3216–3244` | 无活动订单、Host或恢复引用的退役实例历史 | 当前fence、旧会话拒绝依据、活跃策略及高水位 |
| Cutover activation，8项 | `src/recovery_cutover.zig:302–308,404–439,462–480` | 已承接的旧activation明细 | generation、当前release/strategy/schema、未完成切换 |
| completed forced allocation，32项 | `src/account_coordinator.zig:509–517,688–762` | source/allocation/slices/ack全部持久闭合 | suspense、source_positions、未完成allocation、delivered_mask及风险锁存 |
| 独立GatewayOwnership，32项 | `src/account_coordinator.zig:398–427` | 已闭合且持久承接的路由记录 | Unknown、未闭合命令、各分片latest_fencing_tokens |

Coordinator summaries/leases/deliveries各4项是按分片替换的当前状态，不是可清理的累计历史。`account_coordinator.zig:529–554` 的连续shard_sequence和portfolio/domain/account归属、lease版本及风险占用保持。

## 接口与归档协议的必要范围

- 同gate_identity合法更新open状态（`operational.zig:217–226`），须区分稳定gate定义/当前状态与一次输入事实，不能将gate_identity与完整change摘要当作不可变事件键。
- command先检查expiry再检查duplicate（`operational.zig:137–143`）；冷历史查证不能绕过过期、target、version或SafetyGate，也不能重新执行EnableTrading。
- Core pin全部control_fact_sequences（`trading_shard.zig:835`）；command和sequence必须一起归档/回收，保留当前authorizing/control依据及RiskFactRefs引用。授权调用与authority_control_barrier一起核对（`:1637,3172–3174`）。
- Cutover是独立activation历史消费者，只回收Core fence不会解除其8项容量边界。
- GatewayOwnership重复`(shard_id,command_id)`当前直接拒绝；历史键须绑定account、shard、command、order、revision和fencing token，回收后不得重记/重发。
- 复用Store Batch/Receipt/Proof以及“准备当前已提交状态→发布认证历史→durable commit→原子回收”；Core不做历史I/O。冷查询缺失/超时保持候选及新增风险关闭，冲突拒绝。
- 单分片control/fence属于TradingShard Owner；Coordinator属于共享账户的独立单Writer，须在现有control stream及CoordinationJournal上提供持久Owner/协调根协议，不能借某个分片的Owner冒充跨分片所有权，也不新增CLI。
- `business_history.zig:161,486`、`cold_business_candidate.zig:45`目前限制decision_log。control/coordinator复用必须显式演进允许域及namespace校验，不能静默放宽。
- CoordinationJournal仍为固定容量（`account_coordinator.zig:166–198`）；需要snapshot与连续tail承接全局协调序列，不reset序列或清空journal。Coordinator snapshot/digest/tail/AccountRecovery同步更新（`:557–596,1097–1224,1329–1465`）。
- forced allocation资格需包括原始AccountFact、来源仓位、完整slices、经济量/fee/penalty守恒及全部分片持久应用和ack。`ackForcedDeliveryFromShard:872–881`及`AccountRecovery:1457–1462`的真实应用要求不能因归档消失；下一source覆盖旧source前需归档完整内容。
- 06/07的经济根承接尚未实现，08实施时重新核对相邻“订单→经济→控制”根及Gateway的非dispatch根承接。Shard内forced经济seen/ledger的持续回收属于07关联范围，不能只通过Coordinator计数掩盖32/64经济容量瓶颈；因此实施顺序选择06→07→08。

格式/调用范围包括Core event/state/journal/registry、snapshot有效前缀/清零/恢复校验/摘要、Coordinator snapshot版本7与journal版本4、GatewayOwnership持久布局、Cutover replay、`four_shard_acceptance.zig`及现有控制事实入口；不需要新Web UI。

## 必须留下的公共行为证据

分别实际跨至少十轮旧容量：320 command、160 gate、160 resolved latch、80 fence、80 activation、320 completed allocation、320 GatewayOwnership，以及十个完整旧CoordinationJournal窗口。每组有实际归档/检查点/恢复，不以总事件数外推。

每组覆盖旧重复/冲突、错误account/shard、过期权限、token/generation不回退、未闭合pin及发布/提交/回收故障；四分片共享账户核对风险上限与归属。forced场景核对真实经济结果与ack，恢复后SDK零新增发送，不能只检查Coordinator数组数量。

以上是实施前源码清点，不是已实现接口或已通过验收。
