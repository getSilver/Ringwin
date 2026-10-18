# 落实权威资产精度与精确经济账务

Label: wayfinder:map
Status: closed

## Destination

按照已接受的多 Venue 数值方案，把交易所确认的费用、返佣及账户金额精确转换为版本化资产原子单位，贯通同一 TradingShard、原币账本、DurableStore 与恢复路径。无法精确表示的事实保持可审计并失败关闭，不把保守估算写成真实经济金额。

本模块于 2026-10-03 发布优化落实 Spec 及 13 张实施 Ticket（02–14）；用户随后通过 `/goal $implement` 授权建立独立工作区并实施。当前按已确认阻塞关系推进，仅执行本地实现和离线验证，不执行在线交易或部署，不因发布计划宣称修复或取得资格。

## Definition of done

- 所有受支持 Asset 的原子精度、来源依据、生效版本及数值范围显式配置，不再由 Venue 私有硬编码解释金额。
- 真实金额精确转换；不可表达、未知资产、精度冲突及溢出均产生可恢复的失败关闭结果，无费用余数被静默丢弃。
- Decimal 保持有界定点合同，无意义小数尾零不引发系数溢出；仍明确拒绝实际越界值。
- 账本按 Asset 记录真实费用与返佣；资产 atoms、Instrument lots、价格 ticks 及结算金额之间使用明确规则转换。
- 费用、余额及账务失败事实贯通既有公开 seam、日志、快照和重放；重复事实无重复经济作用。
- 除内部双层闭合外，还逐 Asset 与独立 Venue 事实精确核对；新版本资格不继承旧取整版本的在线报告。

## Rules

- 复用现有 VenueAdapter、TradingShard、Owner、DurableStore、快照与重放 interface；不增加第二套核心、账本、runner 或测试框架。
- Venue 私有字段和签名语义由 VenueAdapter 处理，核心只接收规范事实。
- 本阶段采用“精确表示，否则失败关闭”；不新增通用任意精度计算或低于资产原子单位的余数账本。
- 数值不可信时关闭受影响范围的新增风险；停止自动重发，不把无法转换的真实成交视为已处理。
- 本 Spec 获准进入实现准备，不等于授权部署、修改历史账、Demo/Testnet/生产写入或自动清理。
- 保留无关工作树改动；只使用本地 tracker，不同步 GitHub Issues。

## Route

父需求：[01：权威资产精度与精确经济账务优化落实 Spec](issues/01-exact-asset-accounting-spec.md)。父 Spec 保持原文、原状态，仅作需求来源，不作为实施 Frontier。

| Ticket | 阶段 | 交付切片 | Blocked by |
| --- | --- | --- | --- |
| [02：停止真实金额取整并持久关闭新增风险](issues/02-fail-close-inexact-economic-facts.md) | S1 | OKX 已确认的费用、返佣和账户金额无法精确表达时，不再制造取整金额；从 ready 接入到核心安全栅栏、Gateway 和重启形成明确故障结果。 | 无 |
| [03：让有界 Decimal 等价文本贯通规范事实](issues/03-normalize-bounded-decimal-ingress.md) | S2 | 受支持输入长度内的长尾零、符号及全零形式产生同一数值和业务身份；真正越界仍经数值故障路径关闭交易。 | [02](issues/02-fail-close-inexact-economic-facts.md) |
| [04：贯通 AssetDefinition 激活与精度范围准入](issues/04-activate-authoritative-asset-precision.md) | S2 | 同一份带来源依据的权威资产配置经生效事件到 Adapter、核心及恢复，决定整数单位和可用交易范围。 | [03](issues/03-normalize-bounded-decimal-ingress.md) |
| [05：贯通高精度结算资产费用与原币账务](issues/05-close-settlement-asset-precision.md) | S3 | 配置精度下的结算资产费用、返佣、现金、posting 与风险计算使用一致单位，单笔和累计金额保持精确。 | [04](issues/04-activate-authoritative-asset-precision.md) |
| [06：精确记录基础资产费用并分离 atoms 与 lots](issues/06-separate-base-atoms-from-trade-lots.md) | S3 | BTC 等基础资产扣费和返佣按真实资产单位更新余额，成交数量保持订单 lots；净资产的交易步长以下余额完整保留。 | [05](issues/05-close-settlement-asset-precision.md) |
| [07：让第三 Asset 费用与返佣形成原币闭环](issues/07-account-for-third-asset-fees.md) | S3 | 已配置第三费用资产与 base/quote 使用同一账本，归属精确；未取得有效估值时明确显示不完整，而非零费用。 | [06](issues/06-separate-base-atoms-from-trade-lots.md) |
| [08：精确接入原币余额与保证金观察](issues/08-preserve-native-balances-and-margin.md) | S3 | bootstrap 和连续账户观察保留原币总额、可用、占用及负债；真实保证金与 USD 估值分开，不因保守风险计算改写来源。 | [06](issues/06-separate-base-atoms-from-trade-lots.md) |
| [09：贯通资金结算及成本、PnL 的精度合同](issues/09-close-native-settlements-and-pnl.md) | S3 | 在新资产单位下既有资金流、资金费和强制执行的经济事实保持精确，成本释放和 PnL 不重复改变现金。 | [07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md) |
| [10：用独立 Venue 事实核对逐 Asset 经济账](issues/10-reconcile-independent-venue-economics.md) | S3 | 本地内部镜像一致但偏离真实金额时，独立 snapshot/bill/fill 核对仍能产生持久 ReconciliationBreak。 | [09](issues/09-close-native-settlements-and-pnl.md) |
| [11：证明精度账务与故障状态的崩溃恢复](issues/11-prove-precision-crash-and-replay-invariants.md) | S4 | 精确金额和未解决数值故障在 raw/规范事实/提交/快照各中断点都能恢复，不丢事实、不重复账、不重新发送。 | [10](issues/10-reconcile-independent-venue-economics.md) |
| [12：只读审计历史取整差额并保留更正边界](issues/12-audit-historical-quantized-fees-readonly.md) | S4 | 审计员可从已有源事实关联旧 Fill/事务，获得真实金额、已记金额及差额，不改写旧账或误授予新资格。 | [10](issues/10-reconcile-independent-venue-economics.md) |
| [13：闭合多 Venue 精确账务公开接缝合同](issues/13-qualify-multi-venue-exact-accounting-contract.md) | S5 | OKX、Binance、Bybit 和 SimulatedVenue 经各自真实 Adapter 的公开路径遵守同一精度、费用、故障与恢复合同。 | [11](issues/11-prove-precision-crash-and-replay-invariants.md) |
| [14：封存完整验收、覆盖矩阵与发布资格要求](issues/14-seal-exact-accounting-release-evidence.md) | S5 | 形成可复现、逐项对应 Spec 的实现证据，明确受支持范围及新源码版本仍需哪些在线资格。 | [12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |

实施票当前状态以各票头部为准；只有无未完成 blocker 的票可认领。阶段是 Spec 的范围分类，实际阻塞以本表为准：07/08 可在 06 完成后分别推进，11/12 可在 10 完成后分别推进；最终封存 14 同时等待历史审计 12 和多 Venue 合同 13。

## Frontier

- 实施票02–14均resolved/completed，无实施Frontier。父Spec01原文及生命周期保持不变；生产配置及新源码在线/生产资格仍需独立授权与实际证据。封存见[覆盖索引](coverage-evidence.md)、[发布证据](release-evidence.md)、[精确manifest](release-evidence.json)。


## Decisions so far

- 2026-10-08：14封存521db8d1实际源码/配置/完整覆盖。Debug与ReleaseSafe根合同各424/424、Linux和Windows ReleaseSafe编译exit0；实际Windows假transport角色/恢复与四shard/三路径通过，顶层资格保持blocked，所有在线not_run/production=false。完整分支及增量双轴审阅已闭合P1/P2，所有实施票02–14完成，无实施Frontier；父Spec生命周期不改，没有部署、账户交易、清理或历史更正。

- 2026-10-08：13实际多Venue公开精确账务合同完成离线切片。Binance/Bybit共享最终Debug/ReleaseSafe各14/14；OKX真实native证据和Simulated原币合同复用同一Owner/ledger/persistence。未知/余数/溢出/冲突/无private link/decoder/现代wallet故障持久关闭；Binance不完整Spot产品/bill scope和Bybit钱包availability保持未解决。Frontier推进14，最终全套/全分支独立双轴审查与源码绑定待执行；线上not_run/false。

- 2026-10-08：12完成既有evidence命令的只读historical子模式与两条固定原币差额；支持严格旧单位/原始哈希/唯一执行/旧posting关联，缺原历史证据保持unverifiable，宽JSON保持精确。两种实际CLI/输入哈希不变验证通过，联合Debug/ReleaseSafe各13/13；没有历史更正或新在线资格。14等待13及最终全套/双轴审查。

- 2026-10-08：11离线恢复切片完成，18个native文件中断场景含恢复途中再故障、32Fill/64ledger/33rd fault、真实WS/REST排列与旧schema拒绝；11/12联合Debug/ReleaseSafe各13/13。Frontier推进13，最终完整套件/独立两轴审查待14，在线未运行。

- 2026-10-08：10完成独立原币cash快照/真实bill链/唯一已应用经济fact完整摘要核对；差异不改账且锁存break。Raw请求/query持久与共享恢复解码器、重复proof sweep及Windows replay→live floor衔接闭合。联合Debug/ReleaseSafe各24/24、实际两种构建Windows离线重启与四shard通过，Linux ReleaseSafe编译通过，两轴审查无剩余重大问题。限定16bill/4query的cash proof，非零position cash保持未解决；在线与production资格仍not_run/false。Frontier推进11/12，完整套件/最终封存待14。

- 2026-10-07：09完成实际OKX资金费原币、完整身份、真实opening时点防重计、未知归属Suspense、gross累计上限及可信Core成本/PnL/强制费用罚金合同；联合Debug/ReleaseSafe各13/13、economics各14/14、协调器ReleaseSafe97/97、实际两种构建离线轨迹恢复一致，两轴最终无剩余重大问题。Frontier推进10，完整回归/封存仍待14，外部组合资金费分配与在线资格未宣称。

- 2026-10-07：07/08实现提交72726cd2；原币第三资产费用、Treasury ownership、未估值报告、账户USD单位分离、连续流与持久重复/冲突、发送前原币证明和配置收紧预检完成。联合定向各35/35、最终健康/连续性各8/8及范围/Gateway定向通过；两轴最终无剩余重大问题。Frontier推进09，全套检查与发布封存待14，新在线/生产资格未运行。

- 2026-10-05：06 完成 native base i128 atoms 与 gross成交lots分离、独立资产posting、非单位lot/tick及dust完整保留；组合卖出、report先于Fill及未确认减量native-amend按唯一已应用经济证据保留库存占用。基础资产超i64、精度/累计/极值/冲突持久失败关闭及无发送恢复通过；Debug/ReleaseSafe综合定向各27/27、实际Windows离线链及Linux编译通过，两轴最终审查clean。Frontier推进至07/08；本地证据不构成新在线或生产资格，父Spec原文/状态不变。

- 2026-10-05：05 完成 checked i128 结算 atoms、显式 tick 单位、独立费用/返佣 posting、风险保守舍入与实际结算精确失败关闭；原始 OKX→Owner 高精度/超 i64/重复/冲突/累计越界/畸形报告恢复通过。Debug/ReleaseSafe 定向各 15/15，实际 Windows 离线链及 Linux authoritative 编译通过，两轴最终审查无剩余发现。Frontier 推进到 06；base atoms 与 lots 分离及第三资产尚待后续票。本地证据不构成在线或生产资格，父 Spec 原文与状态不变。

- 2026-10-05：04 完成权威 AssetDefinition 激活、共享 Adapter/Core/Simulated 配置及持久范围准入；Debug/ReleaseSafe 定向 12/12、实际 Windows 离线进程链及 Linux authoritative 编译通过，两轴最终审查无剩余发现。Frontier 推进到 05；高精度和真实 Venue 来源配置仍为 RecoveryOnly，旧金额/tick 消费者由后续票迁移。本地证据不构成在线或生产资格，父 Spec 原文与状态不变。
- 2026-10-03：用户要求依据当前审查建议及已接受方案形成优化落实计划，并显式调用 to-spec。
- 2026-10-03：用户确认测试接缝采用 `ingestPrivateWs/REST → VenueAdapter.tryDrain → TradingShard.apply`，并经既有 DurableStore、快照和重放验证；Decimal 仅补公共数值 interface 的边界检查。
- 既有成交恢复模块已关闭，本模块复用其公开 seam、幂等与崩溃恢复证据，不以历史关闭状态证明费用精确。
- 首版不在线重缩放已有 Asset 的持久金额，不自动改写历史账，不把资金费分配尾差政策套用到成交费用。
- 2026-10-03：用户确认 13 张实施票及依赖，已发布 02–14，全部保持 open/ready-for-agent，实施 Frontier 为 02。父 Spec 原文及状态未改。
- 28 个 User Stories、8 个 Implementation Decisions 小节、16 个验收场景和六项 Done when 均建立覆盖关系；全部产品验收仍待执行。

## Spec coverage

覆盖依据为[父 Spec](issues/01-exact-asset-accounting-spec.md) 原文。User Stories 使用其原有编号；D1–D8 对应 Implementation Decisions 的八个小节；M01–M16 按 Testing Decisions 验收矩阵原有行顺序编号。覆盖表示需求分配，不能作为实现通过证据。

| User Story | 实施票 |
| --- | --- |
| 01 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 02 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 03 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 04 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 05 | [07](issues/07-account-for-third-asset-fees.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 06 | [07](issues/07-account-for-third-asset-fees.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 07 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 08 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 09 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[05](issues/05-close-settlement-asset-precision.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 10 | [04](issues/04-activate-authoritative-asset-precision.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 11 | [04](issues/04-activate-authoritative-asset-precision.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 12 | [02](issues/02-fail-close-inexact-economic-facts.md)、[04](issues/04-activate-authoritative-asset-precision.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 13 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 14 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[04](issues/04-activate-authoritative-asset-precision.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| 15 | [02](issues/02-fail-close-inexact-economic-facts.md)、[03](issues/03-normalize-bounded-decimal-ingress.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 16 | [02](issues/02-fail-close-inexact-economic-facts.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 17 | [02](issues/02-fail-close-inexact-economic-facts.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 18 | [02](issues/02-fail-close-inexact-economic-facts.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 19 | [02](issues/02-fail-close-inexact-economic-facts.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 20 | [02](issues/02-fail-close-inexact-economic-facts.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 21 | [02](issues/02-fail-close-inexact-economic-facts.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 22 | [04](issues/04-activate-authoritative-asset-precision.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| 23 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 24 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md) |
| 25 | [08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| 26 | [12](issues/12-audit-historical-quantized-fees-readonly.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| 27 | [13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| 28 | [02](issues/02-fail-close-inexact-economic-facts.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |

| Implementation Decision | 实施票 |
| --- | --- |
| D1 所有权与最小实现 | [02](issues/02-fail-close-inexact-economic-facts.md)、[07](issues/07-account-for-third-asset-fees.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D2 真实金额与保守估算 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D3 权威资产精度及范围 | [04](issues/04-activate-authoritative-asset-precision.md)、[05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D4 有界 Decimal | [03](issues/03-normalize-bounded-decimal-ingress.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D5 不可表达事实、余数及恢复 | [02](issues/02-fail-close-inexact-economic-facts.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D6 原币账本与单位转换 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D7 Schema、历史事实及资格 | [02](issues/02-fail-close-inexact-economic-facts.md)、[04](issues/04-activate-authoritative-asset-precision.md)、[05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| D8 优化落实顺序 | [14](issues/14-seal-exact-accounting-release-evidence.md) |

| 验收场景 | 实施票 |
| --- | --- |
| M01 USDT 两组长小数费用 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M02 十笔 USDT 微费用 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M03 BTC 九位费用 | [02](issues/02-fail-close-inexact-economic-facts.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M04 返佣、零、缺失及字段粒度 | [02](issues/02-fail-close-inexact-economic-facts.md)、[05](issues/05-close-settlement-asset-precision.md)、[07](issues/07-account-for-third-asset-fees.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M05 base/quote/第三 Asset 费用 | [06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M06 Asset atoms 与 lot/tick 分离 | [06](issues/06-separate-base-atoms-from-trade-lots.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M07 精度配置激活、冲突与历史解释 | [04](issues/04-activate-authoritative-asset-precision.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M08 Decimal 等价文本及格式/长度 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M09 整数、缩放、累计及容量边界 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[04](issues/04-activate-authoritative-asset-precision.md)、[05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M10 无 pending 的 ready 数值失败 | [02](issues/02-fail-close-inexact-economic-facts.md)、[08](issues/08-preserve-native-balances-and-margin.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M11 输出容量不足及持久提交失败 | [02](issues/02-fail-close-inexact-economic-facts.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M12 合法乱序、WS/REST 补证及重复 | [05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M13 相同身份内容冲突 | [03](issues/03-normalize-bounded-decimal-ingress.md)、[05](issues/05-close-settlement-asset-precision.md)、[06](issues/06-separate-base-atoms-from-trade-lots.md)、[07](issues/07-account-for-third-asset-fees.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M14 崩溃、快照、旧 schema 与 replay no-send | [11](issues/11-prove-precision-crash-and-replay-invariants.md)、[12](issues/12-audit-historical-quantized-fees-readonly.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M15 独立 Venue 经济对账 | [08](issues/08-preserve-native-balances-and-margin.md)、[09](issues/09-close-native-settlements-and-pnl.md)、[10](issues/10-reconcile-independent-venue-economics.md)、[11](issues/11-prove-precision-crash-and-replay-invariants.md)、[13](issues/13-qualify-multi-venue-exact-accounting-contract.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |
| M16 历史取整样本只读审计 | [12](issues/12-audit-historical-quantized-fees-readonly.md)、[14](issues/14-seal-exact-accounting-release-evidence.md) |

| 父 Spec Done when | 落实位置 |
| --- | --- |
| 1：S1–S5、范围明确且无真实金额取整 | 02–13 分段实现；14 汇总实际证据 |
| 2：精度来源可追溯、三家 Adapter 无独立常量 | 04 激活与替换；13 共享合同；14 来源及范围证据 |
| 3：原币精确表达、内部闭合及独立对账 | 05–09 经济闭环；10 独立对账；13 跨 Venue |
| 4：无 pending、队列满、存储失败及重启锁存 | 02 故障闭环；11 全链故障矩阵；13 跨 Venue |
| 5：重复、冲突、乱序、快照和无发送重放 | 03、05–10 各切片；11 恢复证明；13 共享合同 |
| 6：历史账、旧资格及未执行状态边界 | 12 只读审计；14 发布证据与资格约束 |

每票均遵守父 Spec 的 Out of Scope 和本地图 Rules；不把排除项转成待实施功能，不授权线上写入或历史账修改。


## Reused evidence

- [业务逻辑规格地图](../quant-trading-system/map.md)
- [权威数值表示](../quant-trading-system/issues/10-numeric-and-event-representation.md)
- [账本、PnL 与费用归属](../quant-trading-system/issues/15-accounting-and-pnl.md)
- [事件 schema 与兼容性](../quant-trading-system/issues/29-event-taxonomy-and-schema-compatibility.md)
- [正式多 Venue 方案](../../docs/多交易所适配方案.md)
- [成交恢复合同](../venue-fill-recovery/map.md)
- [Windows 进程链验证范围](../windows-process-chain-verification/map.md)
- [Linux 生产资格范围](../production-readiness/map.md)
- [领域词汇](../../CONTEXT.md)
- [Venue seam 决策](../../docs/adr/0001-separate-venue-execution-and-market-feed-seams.md)
- [DurableStore 合同](../../docs/adr/0004-durable-store-persistence-contract.md)
- [权威安全状态 schema 决策](../../docs/adr/0006-authoritative-safety-state-schema-9.md)
- [Windows 验证资格合同](../../docs/adr/0008-windows-verification-runtime.md)
- [审计与语义摘要分离](../../docs/adr/0009-separate-semantic-authority-digest-from-audit-trace.md)

## Not yet specified

- 生产 Asset 精度及其权威来源证据在 S2 验证，不从链上小数位、提现精度或订单 lot 推测。
- 新 schema/registry 的具体编号在实施时核对当前源码确定，不预占版本。
- 独立余数账本、在线精度重缩放和历史账更正实施均不在本 Spec 内默认授权。

## Out of scope

- 任何产品代码实施、线上交易、部署及历史账修改作为本次规划交付。
- 新增 Venue 或交易产品、通用 transport/plugin、第二套控制面和通用估值平台。
- 任意长度小数精确计算、宽松对账容差、虚构 Treasury/Suspense 金额。
- 以离线通过代替新源码版本的在线或生产资格。
