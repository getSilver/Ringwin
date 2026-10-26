# 04 域内多 VirtualPortfolio 实现交接设计

状态：2026-10-24 的实现前设计；下文建议类型名不是最终接口。依据 ADR0012/0013/0016/0017/0020；不修改原04五条条件。当前实现与验收以原票的最新证据为准。

## 2026-10-25 已落实的选择

- 保留 `Domain.portfolio` 作为固定主组合及旧接口锚点，增加有界 membership 与每组合 risk slice；同一账户品种仍只归一个 Domain。
- 每账户仍只有一份物理账户投影、原始事实、去重集合和历史根；主组合及附加组合分别保存经济 Layer。资金转移、OMS 订单、成交来源及逐策略授权都显式绑定实际组合。
- 同一个 Host 会话下每个策略使用独立的逻辑 Gateway；不增加 Python 进程或物理 pipe。配置域继续要求完整双成员 IntentGroup，不开放单腿准入绕过共同裁决。
- 策略配置版本与物理 Adapter 配置版本独立。持久 DispatchProof 保留策略授权证据，发往 Adapter 的 OrderCommand 使用实际 route 的物理配置版本。
- 本轮没有新增账户资金费的猜测分摊机制。部署只能证明 Domain、不能证明具体组合时，原文仅应用一次账户经济并保留 Suspense；单组合的既有确定归属保持兼容。下文 FundingAllocation 是后续获得真实归属证据时的设计方向。
- 真实四 Owner 验收已获得成交方向抵消：两组合毛保证金8、原生账户净保证金4、不可分配观察收益4，RiskLease及剩余额度不增加，checkpoint/recover 收敛。剩余专项回归和审查完成前，原票保持 in-progress。

## 最小选择及不变量

保留四个 Domain/Owner、一个共享 Gateway/Adapter；只让其中一个 Domain 拥有两个 VP。配置与运行容量首版明确为每域最多4 VP，整个部署最多16 VP；账户仍4、Domain仍4、Instrument ownership仍500。不是增加16份 TradingShard 或16份物理账户。使用有界数组和显式 count，超额拒绝且不部分提交。

每个账户一个 economics.Projection，其中一个 exchange Layer、一份 treasury/suspense、一个 canonical fact去重/历史集合；Projection拥有多个带身份的 portfolio Layer。不要为每个VP复制整个 Projection，后者会重复exchange、seen、原始事实和历史根。账本仍一个有界有序集合，条目绑定 portfolio；按VP读取即可独立守恒，不需第二ledger writer。

VP授权放Domain级（一个VP可用多个账户），经济Layer放Account级。Domain全局OMS保持一份；订单/命令/替换均携带不可变portfolio。所有配置、经济、OMS、风险及lease变更继续经 Owner -> TradingShard.apply 单次原子提交；Coordinator只协调账户预算和投递，不拥有策略交易权。

## 当前必须改到的调用路径

| 位置 | 当前单VP假设及改动 |
| --- | --- |
| `src/trading/deployment_allocation.zig` Domain/BindingRecord/validateComplete/contentDigest/validateSnapshot | Domain.portfolio唯一；改独立Portfolio membership rows；账户品种Ownership行继续只归Domain，不重复为VP造Ownership行 |
| `src/trading/trading_shard_event.zig` VirtualPortfolioActivation/StrategyActivation/HostActivated/授权/资金payload及encode/decode | 增显式VP，逐VP激活、资金和Host授权；旧未配置fixture只允许明确单VP兼容规则 |
| `src/trading/trading_shard.zig` AccountState(~261)、账户切换(~1588)、accountState | 物理字段保持账户级；portfolio资金状态移进对应Layer；域授权不得随account partition切换 |
| 同文件 apply前置配置验证(~1533)、nextStrategyActivationIdentity(~1651)、qualifiedGroup(~2944)、strategy准入(~3013)、refs(~2679)、payload分支(~5117-5441) | 以VP查授权、规则、配置、余额；不能用最后激活的scalar覆盖其他VP |
| `src/execution/oms.zig` Intent/Order/Command/Replacement、applyQualifiedGroup、intentFingerprint、replacementIntent/confirmReplacement、reservationsForAccount | 加VP不可变归属、摘要绑定；补reservationsForPortfolio(account, portfolio, asset)而保留账户汇总 |
| `src/portfolio/economics.zig` Projection/Layer、applyCanonicalFillWithSource、applyFeeAdjustment、applyFundingWithSource、applyForcedWithSource、assertClosed、digest、archive qualifiers | 按来源VP选择Layer；exchange只应用一次；账本及历史保存完整归属；守恒改sum(all VP)+treasury+suspense=exchange |
| TradingShard fill(~4222/~5512)、fee(~4060)、funding(~2535/~5542)、forced(~5593)、residual(~4005)、cycles引用(~2000/~2063) | fill从order.portfolio取值；fee从resident/cold FeeOrigin；funding/forced冻结明确分配；residual/cycle按实际owner，不从shard scalar补 |
| `src/portfolio/account_coordinator.zig` allocate验证(~365)、summary(~500)、acceptVenueFactFromGateway(~3813)、feeOriginVerified(~3794)、acceptForcedVenueFact(~3679)、ACK(~4002) | summary/lease绑定Domain+account+deployment而非一个VP；路由Domain，核验内部VP归属；forced冻结到VP |
| `src/strategy/strategy_host_gateway.zig` configure/rebind/authority检查(~265/~405/~488)、`strategy_host_lifecycle.zig` HostActivated同步(~426) | 当前一个config.authorization和activation_floor；按strategy/VP保存授权与floor，frame已有portfolio与strategy身份，应交叉核验 |
| `src/trading/trading_shard.zig` validateSnapshot(~5887-6007)、风险refs校验(~6342)、digest(~6771)、mappedTail(~5704) | 验证VP membership、active prefix、订单和经济来源一致，摘要逐VP完整绑定；不能漏account partitions |
| persistence canonical_event_codec/snapshot_codec及业务history、Gateway proof/快照编码 | layout改变分别升级；proof/订单历史中VP纳入规范摘要；旧Root继续采用失败关闭策略 |

实现前对新增portfolio字段及每个被改函数执行rg callers；上述行号会随并行04改动漂移，用符号定位。尤其不要批量把self.portfolio_identity替换成当前slot：snapshot/冷history/forced历史归属不等于当前激活策略。

## 配置与授权的具体表示

建议 `Domain {identity, stream}`；新增 `Portfolio {identity, domain}` staged行，Header.portfolio_count，Configuration.portfolios[16]。新增 `PortfolioSlice {account, asset, portfolio, atoms}` staged行，与现有Domain Slice并存；每(account,asset,domain)内VP Slice之和不得超过Domain Slice，不从bootstrap余额派生第二份资金。每VP初始资金只能从该账户treasury明确转入一次；VP slice仅额度，不是余额。

`BindingRecord` 改绑定Domain和sealed配置digest（不冒充单VP）；FundingOwnership另带显式portfolio或Allocation证明。配置seal验证portfolio全局唯一、一个domain归属、非零、所有slice引用有效、VP域拥有被交易(account,instrument)、资金不超配。账户品种仍配置一条Ownership(account,instrument,domain)，两个VP授权引用同一条。

建议Domain级 `PortfolioAuthority {portfolio, active_strategy_instance, strategy_config_version, strategy_activation_identity, activation_sequence, host_activation_identity, host_activation_sequence, next_intent/highwaters, fences, trading_authorizations}`；共用Host session generation/pipe，不复制Host进程权威。按 `(strategy_instance, portfolio)` 查匹配，不以数组最后一项为active。相同VP第二个并行有效strategy必须拒绝；successor只替换本VP。Host恢复/激活/撤权事实必须选择VP/strategy；host整体故障撤权其所有实例，单VP撤权不能覆盖其他VP身份。

PortfolioState仅保存Layer及资金激活/额度状态。AccountState保留exchange snapshot/nativeMargin/observed baseline/last configuration与一个Projection。instrument registry中的授权须拆出VP维度；市场与规则仍共用。避免复制125份完整规则到每VP。

## 经济来源：03不能倒退

Fill/fee：OMS订单创建时冻结VP，cancel/amend/replacement必须继承且target校验同VP。Command/DispatchAuthorityRefs或其绑定的RiskFactRefs明确VP，Gateway复核与Owner订单一致；wire归属仍Domain/command，不引入VP自选路由。`FillSource.portfolio=order.portfolio`；FeeOrigin从原始fill建立，冷查询验证完整account/domain/stream/portfolio/strategy/order/fill，不与当前激活VP比较。Fill先/后report仍按唯一已应用canonical fill数量校验，不改OMS累计语义。

Funding：旧 `FundingSource`只有一个portfolio和BindingRecord.portfolio，不能把账户funding复制给每VP。原始source/envelope只保存一次；建立不可变 `FundingAllocation {source_identity, source_digest, account, instrument, rules_version, deployment_digest, cut_barrier, cut_digest, slices[]}`。每slice显式portfolio、signed amount、来源持仓/时点证据。已明确单VP来源直接一slice；账户级总额缺少时点持仓/官方费率与分配证据时保留Suspense，不能按当前仓位/余额猜。若依据资金费时点冻结signed position及费率分配，逐VP金额可异号，sum(slices)+明确treasury舍入尾差必须等于原始source.amount；不能按绝对仓位分摊净funding。原始source只推进一次exchange，slice只推进VP。

Forced：当前 `ForcedOwner[4]`/`ForcedContributionBasis.positions[4]`只足够每Shard一个VP。保留4个目标Shard和4份ACK，但每Shard basis增加最多4条 `PortfolioContribution {portfolio, quantity, position_cost, rules_version}`；共最多16条，绑定每Shard cut barrier/digest及配置摘要。不能只存域net2丢失A+3/B-1。Coordinator收到source前必须等更早经济投递提交；冻结basis与allocation持久化后不重新读当前仓位。域内分配由该唯一TradingShard依据冻结basis验证并在同一Owner事务应用，Coordinator ACK绑定整份域内allocation digest，而非收到消息即ACK。

Forced分配必须显式数量/PnL/fee/penalty，每VP不得错误穿零；冻结贡献既包括方向也包括成本。比如net+2账户sell1 forced，选择明确A减1、B不变的合法allocation；不能按net权重给B反向增仓。无法证明来源或VP分配则继续原03 Suspense/Break，不补猜测。archive完整保留canonical source、16条basis、分配slices、逐域commit/ack；首次apply-before-ack崩溃重放不重复扣账；all-target经济commit+ACK后方可认证归档。Shard归档闭合证明校验其内部所有VP slice及原Coordinator control stream。保留ADR0016历史根与冷重复协议。

## 风险与reduce-only

风险输入选中VP Layer/该VP余额与OMS预留；account检查聚合所有VP，lease仍Domain/account共用一份，组候选使用同一临时工作状态逐成员扣毛占用，整组失败回滚。`GrossPortfolioMargin=sum_vp(position margin + live increasing OMS reservations + fee buffer)`；任何VP抵消都不降低这个数。不能把same-account多个VP的lease复制成各自全部预算。

PortfolioReduceOnly比较本VP方向与绝对量；VenueReduceOnly比较物理net，分别保留。例如A+3/B-1、net+2，B买1关闭short使net+3：组合减仓但Venue增仓，不得强行标venue_reduce_only；必须通过物理风险/能力/lease条件，否则拒绝。A卖1既组合减仓又使net+1。CancelConfirmCreate撤单确认前旧reservation继续占用；重建时按原VP重新检查，不允许换VP释放旧资金供新owner。取消可以保持账户级，但target订单归属仍受授权约束。

## 持久格式与容量

当前父任务working baseline canonical18/journal49/state53/registry47；最终在合并完成后统一递增实际受影响格式，不让各slice独立硬编码同一个新版本。DomainAllocationV1变V2；canonical/typed event codec、state/journal/registry、Coordinator快照/事件、Gateway proof/checkpoint、history typed记录布局逐个核对。旧configured格式失败关闭，不自动把一个portfolio映射到新数组。保留旧fixture的源码默认仅用于unconfigured明确单VP；configured任何缺VP或不在membership必须拒绝。旧snapshot不是源码fixture兼容范围。

新增可变数组只编码active prefix，恢复检查count、身份、引用、sum与配置digest后发布。snapshot/digest/history绑定VP slots按身份规范顺序；原始经济事实去重按原source身份一次，allocation slice另带(source,portfolio,index)身份，拒绝同source不同分配。经济窗口数量/覆盖计数仍数原始canonical facts，不能因为两VP分摊把fact_count翻倍；逐VP账本与allocation覆盖另验。

VP Layer[4]不会扩OMS订单/命令、max_facts、ledger或125 instruments上限；现有容量共享。allocation16 slices后必须测编码最坏长度，尤其forced source/archive现有固定buffer；不足先增经过计算的有界buffer或分阶段行，不扩大未经验证Venue帧。snapshot按值复制/stack大小须量测；不能复制完整TradingShard充当每VP上下文。容量满显式背压/关闭新增风险，不覆盖未归档记录。

## 顺序纵切（每步单独RED后GREEN）

1. 配置/授权：Owner配置一个Domain两个VP，给各自资金及strategy；A、B都可提交首意图，A撤权后B继续，同账户品种跨Domain配置仍拒绝。先红在真实Owner.apply；绿改deployment/event codecs/VP authorities，其他行为不顺手重构。
2. 订单/成交：同一Gateway/Adapter给两个VP下真实规范订单并回报成交，读取Owner结果A+3/B-1、exchange+2，fee只扣fill原VP。红覆盖伪造VP、cancel/amend换VP和report/fill两种顺序；绿改OMS归属、Projection Layers、fill/fee与proof。先让此slice可恢复，再推进资金费/forced。
3. 毛风险：两VP的独立资金约束+Domain共享lease；同批两请求不能双花。红覆盖B关闭short引起Venue增仓、CCC旧预留未释放和net benefit不增加headroom；绿改risk输入及summary聚合，不动root nativeMargin公式。
4. Funding/forced：在当前03真实CoordinatorOwner协议fixture添加域内双VP；冻结后再收到仓位变化不得改allocation。红覆盖原source重复/内容冲突、allocation冲突、Owner提交后ACK前崩溃、全ACK归档后冷重复；绿扩basis/source/archive及逐VP守恒。
5. 四Owner方向抵消：扩 `shared_gateway_venue_acceptance.zig` 的configured初始化，0号Owner两VP，其他三个Owner各一VP且只拥有其他Instrument；仍一个Gateway/Adapter。走真实下单成交/路由，不能直接塞coordinator summary或Layer。
6. 恢复/原因锁存：在上述轨迹多个cut恢复Owners/Gateway/Coordinator，比较per-shard seq、经济/风险、gate、lease及同屏障CanonicalStateDigest，恢复send_count不增加；缺native输入Unknown、差异锁存、重复、原因解决/人工恢复保留原04五项。完成后双轴审查与scope检查；原票只在全部证据满足后由root更新。

## 验收金额字面量（独立预期，不从被测实现重算）

首选零费用的simulation规则，quantity lot=1，price tick价值=10 settlement atoms，乘数=1，initial margin=1000bp，无附加initial buffer，maintenance=500bp；保守费缓冲0（该规则合法性以现有rules validator为准，若要求非零用单独明确字面量重算，不能跳过validator）。开仓前Treasury100，给A30、B10，剩余Treasury60，明确记录两次资金转移。

在同account/instrument、单向Venue模式，A buy3 @10 -> A+3；B sell1 @10（非VenueReduceOnly）-> B-1，exchange+2；所有订单成交/终态reservation释放。VP gross初始margin分别3、1，总4；canonical native Venue initial_margin=2，AccountNettingBenefit=2。全部费用/PnL=0，VP现金30/10、Treasury60、exchange cash100；无pending OMS，故2的差额完全来自方向抵消。验证策略加总signed position=2，但保证金按绝对量4。另三Owner保持其其他品种零仓/无预留，四份摘要有效且不虚造额外0号VP资金。再次发布相同native fact不改4/2/2；风险预算不能从2升为4或从余额恢复额外2购买力。

如果沿用fixture非零安全缓冲，保留A+3/B-1与native2，显式断言gross的相应保守字面量并分别解释费用/缓冲；严禁用OMS占用补出假方向差额。

## 并行工作hunk分界

- root：nativeMargin math、AccountProjection native完整性、ForAccount summary、reconciliation/Unknown及当前04 fixture基础。
- Risk/Econ量化agent：当前risk/economics量化小hunk及TradingShard对应payload；VP schema实施必须先合并这些hunk再改Projection结构，禁止全文件覆盖。
- 新实施agent第一轮：deployment_allocation、trading_shard_event codec、OMS及授权类型；TradingShard只改配置/authorization/intent小hunk，先不碰nativeMargin summary实现。
- 第二轮：economics Projection/来源/守恒与TradingShard fill/fee/funding/forced；先通知量化agent结束同文件写入。
- 第三轮：coordinator summary/forced basis/fee证明/history、host gateway/lifecycle、snapshot digest和真实fixture。此时root summary改动必须保留；native物理投影不拆VP。

不在本任务提交代码，不创建新GitHub事项，不更新地图或原04勾选。实现agent按每步报实际失败与通过证据；本文不是已实现或生产资格声明。

## Primary兼容入口的最小表示补充

可保留Projection.portfolio作为固定primary VP Layer，新增primary_portfolio_identity、extra_portfolios[3] {identity,layer}与count；统一 `portfolioLayer(id)` / `portfolioLayerMutable(id)` 查primary或extra。primary是配置中稳定指定的identity，不是最近激活的VP，不随执行切换；所有configured生产入口必须传identity。保留 `.portfolio` 直接访问仅作旧单VPfixture/明确primary展示，账户汇总与多VP经济路径必须枚举全部；不能用primary作为隐式fallback。这样避免立即改动大量单VPfixture，同时仍只有一个exchange和一个原始事实集合。AccountState不按VP复制，HostSupervisor也不按VP复制。

同理保留TradingShard现有strategy scalar为primary兼容视图，新增最多3个额外PortfolioAuthority；新逻辑统一authorityForPortfolio/authorityForStrategy查找。禁止用临时切换scalar跑完整apply，期间共享history/native状态和失败回滚很容易被覆盖。HostSupervisor保留唯一session/pipe，Gateway Config的授权表示改为bounded instance列表，每实例独立activation floor/cursor；外层session/frame连续性共享，输出frame的strategy+portfolio选择唯一授权。

真实验收必须从Host输出开始：同一域Host会话内A、B两个StrategyInstance完成各自HostActivated屏障、应用各自activation事实后输出两个独立OrderIntent，再经Owner/OMS/一个Gateway/Adapter成交；不能fixture直接canonical fill造A/B仓。现有IntentGroup同strategy限制可保留，验收发两条单意图即可，无须引入跨strategy group；若组本来只归一个策略，其约束不因域内多VP移除。先完成primary兼容配置RED/GREEN不能被视作04完成，最后必须追加双实例Host输出及stale activation/cross-VP伪造拒绝的公开验收。
