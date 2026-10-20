# H2/H3 权威边界设计提案

日期：2026-10-20。对应 [01](issues/01-authority-boundary.md)。状态：**proposed，等待架构与追加拆分确认**。
这是实现设计，不是已实现能力或运行资格。基于 `e5731d6b173c7f4ce3ad1457280fa72d313d3ea0` 加当前未提交的目录迁移工作树；路径以当前工作树为准。既有迁移不属于本次提交。

## 1. 当前源码支持到哪里

| 公共路径 / 证据定位 | 当前能力 | 不能据此推断的能力 |
| --- | --- | --- |
| `src/strategy/strategy_host_gateway.zig`：`Decision`、输出帧解析（`output_header_len=128`、`order_intent_len=80`，V1 固定单条） | 校验单意图会话、身份、cursor 与 framing | 两条输出不构成完整组传输或共同准入 |
| `src/trading/trading_shard.zig`：`account_configuration`、Host 意图身份检查、`handleOmsGroup`、`qualifyOmsGroup` | shard 一次配置一个 `exchange_account_identity`；Host 账户必须匹配；组先在 candidate 上校验再发布 | 同 shard 双账户、跨 shard 原子准入均未实现 |
| `src/execution/oms.zig`：`Intent`、`IntentGroup`、`applyQualifiedGroup` | 最多 4 个成员、稳定连续身份、逐成员 reservation/command；`Intent` 本身没有账户字段 | 给内部组填两个 Instrument 不会生成两个账户归属 |
| `src/runtime/demo/demo_authority.zig`：`Owner.apply` / `applyCommittedCandidate` | candidate journal append、Store commit 成功后才发布 shard 状态和返回命令 | 顺序调用两个 Owner 不构成一个持久事务；此 Owner 位于 Demo 组装层，也不证明生产已有该集成 |
| `src/portfolio/account_coordinator.zig`：`publishSummary`、`allocateLeases`、`CoordinatorOwner` | 单账户、最多 4 个 shard 的摘要、保守 gross 租约、独立 control Writer、恢复与历史 | 不是跨账户 IntentGroup 提交者；摘要不是实时余额读锁，也不含周期品种独占协议 |
| `src/execution/execution_gateway.zig`：`sendFromShard`、`routeFor`、持久 attempt/outcome | 账户路由、命令来源、风险与权限事实复核；不确定发送持久化与锁存 | 路由支持多个账户不代表上游具备跨账户共同提交 |
| `src/testing/regression/trading_shard_tests.zig`：组回滚、逐项发送结果、Unknown 保留预留；`src/testing/acceptance/core/coordinator_safety_acceptance.zig`：四 shard 租约与恢复 | 已有单账户公共事务/恢复保障 | A/B 与 A/C 的周期占用竞争尚无公共实现证据 |
| `src/testing/acceptance/accounting/native_multi_venue_accounting_acceptance.zig` | Binance/Bybit 私有输入分别经过 Owner 到账本、重放及故障验收 | 测试名称中的 multi Venue 不能证明同时两账户共同准入 |

组合结论：单账户多品种组可走内部核心路径；同账户多 shard 可使用既有账户协调合同，但没有跨 shard 组事务；双账户同 shard 当前账户配置不支持；双账户跨 shard 当前没有共同提交协议。04 可以独立完成候选传输，05 前不能开放双账户发送。

## 2. 备选与建议

| 方案 | 权威与提交方式 | 代价 / 限制 |
| --- | --- | --- |
| A（建议） | 一个 DecisionDomain / TradingShard / decision Writer 拥有有界多个账户分区，完整组作为一个权威事务提交 | 需演进账户表示、经济投影、OMS 归属、快照与 Gateway 证明；同一品种竞争必须共置；不能按改两个字段估算 |
| B | 保留账户单 shard，增加跨账户持久协调协议，参与者 prepare、冻结、全局 commit、投递 ack 后发送 | 新协调权威、独立日志与根、参与者恢复/孤立 prepare/租约撤回协议；不能复用单账户 Coordinator 身份冒充全局提交；需要单独设计和拆票 |
| C | 两腿独立接受或 Python 锁表 | 不能满足共同准入与故障后唯一占用；不作为需求实现 |

建议确认 A 及第 9 节追加拆分。首版一个交易策略实例对应一个 VirtualPortfolio，使用恰好两个已配置账户；竞争账户集合 A/B、A/C 可以在同一 owner 配置中包含第三账户。实现必须通过显式容量配置给出账户/周期上限，不能把“恰好两腿”误写成 owner 只能容纳两个账户。跨 shard 组、跨 owner 的同账户品种竞争首版拒绝；不隐式搬迁现存组合或重新归属存量订单。

同一 `(ExchangeAccount, Instrument)` 的所有新增周期入口必须绑定唯一 owner，覆盖其他策略和单意图入口；共置的是整个冲突连通集合，不仅一对腿。不同品种可由其他 shard 使用有界不重叠 RiskLease；若现有配置无法证明品种唯一归属或资金租约不重叠，禁止新增风险。账户共用凭证仍遵守现有 FailoverGroup 与网关隔离规则，不因共置而弱化。

## 3. 唯一所有者和校验

| 事实 | 唯一权威 | 边界要求 |
| --- | --- | --- |
| ExchangeAccount、Venue、Environment、凭证路由 | 核心版本化配置；Gateway 复核绑定 | 不由 Python 提交新账户绑定；每成员引用配置内账户，账户与 Instrument 的 Venue/产品/环境兼容 |
| Instrument / Asset / rules | 核心 registry 与授权事实 | 价格和数量携带品种与规则版本，金额携带 Asset；不跨资产直接相加，不跨账户借余额 |
| VirtualPortfolio、StrategyInstance、DecisionDomain | 核心激活与版本化配置 | 一个组合一个 owner；两腿必须同策略、组合、domain；禁止仅因账户相同就改变订单经济归属 |
| 账户经济余额、组合余额、Fill 与账本 | owner 内按账户分区的经济投影与唯一账本 | 组合视图可聚合已应用账本，不能把聚合余额作为任意账户可花资金；适配器只提供 canonical 观察事实 |
| RiskLease | 每账户既有 Coordinator 授予该 domain 的权限 | 单一 owner 的本地实际 reservation 是唯一消费投影；Coordinator 摘要用于保守分配，不复制可用现金 |
| RiskDecision / RiskReservation / OrderCommand / ClientOrderId | 核心风险与 OMS，经 Owner 持久提交 | Host 只提出请求；每个对象绑定账户、品种、组合、组与源 stream |
| 活动周期的账户品种占用及释放事实 | 同一个 shard 的权威状态 | 键是 `(ExchangeAccountIdentity, InstrumentIdentity)`，值引用活动周期、组与配置；H2/H3 复用此状态，不能在 Python 或另一个恢复模块建可写锁表 |
| 冻结策略计划、模型、阶段、期限及退出原因 | StrategyPrivateState | checkpoint 引用核心周期身份/屏障；阶段只能请求核心变化，恢复成 Holding 不能解除核心锁存 |

资金 reservation 与周期品种占用分别表示金额和互斥生命周期。订单终态释放金额，不自动释放周期品种占用；相同周期的修复/退出意图可以使用既有占用，但须重新逐项风控，不能变成任意加仓许可。

## 4. 共同准入和竞争序列

1. 04 将完整有界组交给一个核心候选入口；先验证 schema、会话、激活、cursor、新鲜度、连续成员序号、完整组摘要与路由。不能把组拆成独立新风险请求。
2. 由一个 shard 顺序决定组胜负。先检查两个账户品种键及全量成员配置，再在未发布 candidate 中顺序计算全部预留；同账户同资产所有成员累加，跨品种共享资金使用同一账户资产可用额，卖单也扣除同基础币待成交义务。两账户资金不得互抵。
3. 对每账户验证 fresh RiskLease、账户上限、组合/domain/global 保守预算、行情与能力；成交前不把两腿风险当作已净额对冲。不新增“第二份”全局额度；如果现有租约部署没有全局额度来源的可验证绑定，05 必须拒绝该配置。
4. 预检全部订单、命令、预留、周期、占用键、trace/journal 槽位与数值溢出。全部通过才构造一组风险、预留、周期及命令事实。
5. Owner 向同一 decision stream 追加完整事实组并 commit 全组结束屏障，成功后一次发布 candidate。拒绝或 commit 失败不得发布一条腿或任何新发送许可。Store 普通 append 不视为 commit。
6. Gateway 只消费已提交组中的各成员命令，分别复核账户路由、租约、激活与当前 SafetyGate。共同提交不能保证此后的两次外部发送或成交原子。

可检查的确定序列（下述金额为同一个 Asset 的原子量）：

- **A/B 与 A/C 竞争**：AB 先在 shard 顺序提交，占用 `(A,Ia)` 与 `(B,Ib)`；AC 请求 `(A,Ia)`、`(C,Ic)` 时整体拒绝，C 不留下占用/预留/命令。反向到达则 AC 胜出。Python 阶段改变、订单终态或 checkpoint 发布均不释放 A。
- **不同品种共享资金**：A 的可用租约和可支用现金共同允许 100；活动 I1 预留 70，I2 请求 40，整体拒绝；请求 30 才可继续。若同组两个品种请求 60+50，也整体拒绝。账户 B 的余款不能补足 A。
- **其他 shard 共用账户**：账户 Coordinator 将 100 分为本 domain 60、其他 domain 40，两个 owner 分别在额度内消费，不能各自以观察到的余额 100 计算可用资金。重分配额度前必须保守承接原有最大授权及已消费额，不能让在途旧租约与新租约超发；动态扩容协议不在本提案首版开放。

## 5. 状态、发送失败、残余与释放

这里的状态名是设计描述，尚未新增规范枚举或 glossary 术语。

| 核心状态 / 事件 | 保留事实及责任 | 允许动作 |
| --- | --- | --- |
| 候选 / 准入拒绝 | 有可验证身份的业务拒绝按第 7 节提交；无经济占用 | 不发送 |
| 共同提交完成 | 两腿金额预留、周期键占用、原计划引用和组身份已持久化 | 各成员独立检查后发送；IOC 第二腿不得等首腿 Fill |
| 部分 not-sent / 明确拒绝 | 只按证据释放对应订单 reservation；保留已发送腿与周期占用 | 按显式 Independent / CancelRemaining 处理；策略在原计划内请求修复或退出 |
| 任一 Unknown | 命令、发送 attempt、订单、预留、周期键均 pin；锁存新增风险 | 以原身份查询和对账，不自动重发；查询不到本身不等于 ConfirmedAbsent |
| 订单终态但经济未闭合 | 保留周期键；报告累计与唯一已应用 Fill 分别核对，迟到与费用未闭合不能终结 | 继续接入 canonical 安全事实与对账 |
| 退出/对账中 | 保留两账户周期键及剩余经济归属 | 只执行已获权限的撤单和减仓；恢复不延长原持有期限 |
| 残余承接待定 | 不能丢弃基础币费用、永续残仓或 Unknown | 永续未平不得释放；现货尘埃须显式、确定、同 Asset 的承接事实 |
| 核心终结提交 | 两账户订单与经济覆盖闭合、无 Unknown/未决引用、永续仓归零；现货已归零或按已批准政策承接 | 原子记录终结、释放两个品种键；之后才可创建竞争周期 |

现货残余的首版建议：保留在原 VirtualPortfolio/账户账本，转为有明确身份、数量、费用归属和规则版本的不可用于新周期花费的残余项；不写零、不转 Treasury、不重新计价。是否允许它释放品种键必须由策略残余阈值与核心验收共同冻结；在政策未确认/未实现时一律保留占用。未来出售仍通过核心意图并遵守活动周期冲突，不把它当作自动续仓权限。此项属于 A 方案需确认的范围，不预设已经批准。

## 6. 正常与崩溃切点

正常示例：Host 提交实例 S 的连续序号 10/11 → 核心提交完整 AB 组 G → Gateway 为两条命令分别持久 attempt 并发送 → 两账户私有事件经 VenueAdapter 翻译进入公共 apply → 报告与 Fill 任意顺序不重复记账 → 原计划退出后账户对账闭合 → 核心终结 G 并释放两键 → AC 可提交。策略 checkpoint 只保存 G 引用与自身计划/模型。

| 切点 | 恢复必须观察到什么 | 禁止行为 / 后续资格 |
| --- | --- | --- |
| 完整输入之前 / 半帧 | 无完整业务候选；外围诊断可有记录 | 不消费猜测出的组身份，不创建半组 |
| 已校验、尚未 commit | 无已提交准入和发送许可；未提交尾部仍保留物理高水位 | 不借序号重用或删尾恢复写入；遵守 ADR0013 的 closed Owner 合同 |
| journal 追加中 / commit 失败 | 只恢复已提交前缀；失败 Owner 关闭，候选不对外发布 | 不继续发送或假定重试 commit 成功 |
| commit 成功、发布/发送前 | 重放得到完整 G、两个键和全部预留 | 恢复本身不发送；先完成恢复、对账、activation 与安全准入，后续只能显式授权处理未尝试命令 |
| A attempt 持久化后，outcome 前 | A 按不确定路径恢复；B 的状态单独保留 | 不把 A 恢复为 not-sent；不为“补双腿”自动发送 B |
| A submitted，B 明确 not-sent / Unknown | 保留真实分项状态和敞口，按相应策略与安全权限修复 | 不回滚 A 的经济结果；Unknown 不自动重发 |
| Fill 先/后报告、重复、归档后迟到 | 规范业务身份/历史证明、独立已应用累计及账本结果一致 | 不用 OMS 累计加新 Fill 判定重复经济量，不因移出内存忽略迟到事实 |
| checkpoint 在退出阶段，核心尾部较新 | 核心先恢复并追赶，策略按 Cursor 重放到激活屏障；旧实例/会话失权 | 不回退账本、不恢复为 Holding、不重置时限；时钟证据不足禁止新增风险并走安全恢复 |
| 残余承接或终结提交失败 | 恢复旧占用；允许重复证据，不允许提前释放 | 新周期不能抢占旧键 |
| 终结 commit 后、checkpoint 前 | replay 还原同一终结和释放事实 | 不产生第二次承接或二次释放 |

## 7. 下游身份、容量、错误与兼容合同

- 身份：复用 `StrategyInstanceIdentity + first IntentSequence`，成员连续且顺序稳定；完整内容摘要绑定账户/品种/组合/计划引用/政策/配置。HostSession 与 batch 是授权包络，不成为新的业务身份。周期身份绑定最初开仓组，修复/退出组引用该身份；不因 checkpoint/重启创建新周期。
- 业务重复与冲突：完整同身份同内容是无新经济副作用的重复；同身份异内容拒绝并保持新增风险关闭。退出请求也不能覆盖原计划。冷身份需绑定原 stream/account 的认证历史证明，缺失证据不视为首次。
- 身份消费：半帧、未知格式、身份不可验证或旧会话的无效包络不消耗可重放业务序号；具备完整可信身份但过期、风险/占用冲突等业务拒绝，持久记录同一组及全部成员身份的拒绝，不产生预留/命令。提交失败不宣称身份已消费；重启以已提交历史为准且不复用物理序号。精确区分 framing 拒绝与 `StrategyIntentRejected`，04/05 必须逐项证明，不能仅测试异常类型。
- 容量：04 不得放大现有 4 成员上限，H2 先只开放 2 成员组；所有长度先验界限。05a 必须确定并记录账户、周期、每账户品种、订单/命令/预留、拒绝事实、历史 pin 和快照字节的有界预算。新增组需提前预留完整两腿最坏槽位并留独立安全事实容量。满载不得淘汰活动键、Unknown 或无闭合经济引用的身份；返回背压，安全撤单/成交路径继续按其容量合同工作。
- 错误类别：非法 schema/身份、scope/路由不支持、stale、品种占用冲突、资金或租约不足、能力不支持、容量/溢出、历史待证、持久失败分别可观察。业务拒绝不产生半组副作用；持久/可信性故障关闭相应准入。错误枚举值和 wire 编号留给对应实现票，不能在设计文档中假定已经存在。
- 兼容：新增组 frame 使用显式版本/能力协商，不把连续两条 V1 单意图解释为组。旧单账户单意图在原合同下继续有效；新的双账户/周期配置必须拒绝无法表达账户和周期身份的旧输出。核心 journal/snapshot/canonical/registry、Gateway 证明及账户命名空间按实际结构变化分别升级；不猜测双读迁移，不静默把旧经济状态装入新多账户 owner。
- 恢复：canonical digest 绑定有序历史、全部账户分区和周期键，snapshot 不编码指针；策略 digest 不能替代核心 digest。账户相同但 stream 不同的命令 ID 不可混用。业务历史遵守 ADR0011/0013/0014/0016，Unknown 与活动占用不能因归档解除。

## 8. 必须新增的公共验收（尚未执行）

| 后续票 | 公共接缝与结果 |
| --- | --- |
| 04 | 真实 Host framing → 一个候选：两账户成员完整性、旧会话/激活/cursor、重复冲突、半帧半组、容量；逐项记录业务身份是否消费及命令/预留数 |
| 05a/05b | `TradingShard.apply(CanonicalEvent)`、Owner/Store commit → Gateway：账户/品种/组合错配整体拒绝；AB/AC 竞争只成功一组；100/70/40 跨品种资金例；双账户余额不互抵；跨 owner 同品种配置拒绝 |
| 05b | 每个 append/commit/发布切点故障 → snapshot/restore/replay：同一核心 digest、无半组占用和发送，孤尾保持关闭；容量最后槽、整数上溢及安全事实空间 |
| 06/07 | Gateway → 各 VenueAdapter：逐项 attempt/outcome，IOC 两腿独立提交，Post-only 原生能力；一腿失败另一腿真实状态保留 |
| 09a/09b | canonical Fill/report/对账 → 核心周期终结，checkpoint/恢复 → activation：Unknown pin、迟到与归档去重、残余政策、期限与退出锁存、两键原子释放 |

以上向量是提议的公共测试接缝；本设计票只运行现有测试核实支持范围，不新增实现或测试，也不把现有测试通过写成这些新增行为已验收。

## 9. 建议追加拆分及确认门槛

保留原 10 票编号和阻塞边，以下是 05、09 内的建议纵向切片，**尚未创建新票或更改依赖**：

1. **05a 多账户权威表示与持久恢复**：显式账户分区/组合归属/路由、资金租约和命名空间、全链路格式升级；一个合法两账户状态从 apply 到 Store 再 restore，跨 owner 冲突配置拒绝。先确定容量数值和全局预算来源；不能只交付类型。
2. **05b 完整组共同准入及品种占用**：一个候选事务，AB/AC 竞争和跨品种资金验证，持久失败回滚与公共命令证明。依赖 01 确认、04 和 05a；未通过不得启动 06/07 的双账户发送验收。
3. **09a 周期闭合及残余政策**：先验证唯一核心终结、经济闭合与两键释放；依赖 05b，残余阈值/资产规则另须冻结，未冻结保持键占用。
4. **09b 策略恢复与核心占用联结**：依赖 08、09a；Checkpoint → 权威追赶 → 新 activation，覆盖阶段/期限/旧会话/退出锁存。09a 无需等待 Python 模型 codec 才设计核心闭合。

确认后更新 tracker 拆分与阻塞边，接受 ADR0017，并在必要时补 glossary 中已确认的新领域概念；确认前 01 保持 in-progress、05/09 保持阻塞。确认只授权此架构方向与拆分，不授予部署、真实或 Demo 交易权限。
