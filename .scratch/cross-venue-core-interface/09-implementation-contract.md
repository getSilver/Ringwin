# 09 实施合同：待确认项与公共验收路径

更新：2026-10-23。状态：用户新政策为无期限、未冻结残余同所有者复用、人工冻结/解冻；核心改动已完成统一724/724回归；09a按用户定义的显式配置/默认关闭核心范围resolved，09b/09仍待验收。
归属：[09 汇总验收](issues/09-cycle-recovery.md)。依据：[权威设计](authority-design.md)第 5–9 节、ADR0017、[S6 恢复合同](../cross-venue-arbitrage/state-recovery-contract.md)。

## 2026-10-23 当前整合状态

用户已确认09a验收“支持显式配置、未配置默认关闭的核心能力”，本票resolved。生产Asset列表及额度无需在本票启用；后续Web接线、真实Venue资格及连续运行资格保持独立未完成，09b仍受08阻塞。

### 用户最新方向：无期限、同所有者复用及人工冻结（源码与统一回归已完成）

用户明确取消残余最大存续时间，允许新周期花费原账户/VirtualPortfolio/Asset 的未冻结残余，由人工决定冻结及解除冻结。单笔仍限正 sub-lot；累计风险限额允许在受控额度内积累到处置门槛，针对当前未消耗余额而非历史承接总和，具体数值尚未给定。其余周期闭合、Unknown、永续、负资产、费用证据、对账及持久恢复条件保持。见 [ADR0019](../../docs/adr/0019-allow-owned-residual-reuse-with-explicit-freezes.md)。

下文“最大存续时间”“禁止新周期花费”“无解除保留权限”和旧相关锁存是此前政策基线，不再作为新方向的验收要求。联合源码 `88b17505` 已提交，717/717仅属于旧政策证据，不替代新行为验收。

两个 **GPT 6.1 Sol medium** 子代理在主树协作完成当前实现。journal/state/registry **46/50/44**，canonical **16**，StateDigestV14 / SemanticAuthorityDigestV4；旧格式失败关闭，不隐式迁移。

- Closed proof不可变；独立remaining/frozen/消费/credit投影保留原周期、账户、VirtualPortfolio、Asset和Instrument证据。无TTL；未冻结部分默认可由同账户/组合/Asset复用，不跨owner。单笔初次承接仍要求gross/OpenCost/margin精确零且正sub-lot，累计风险额度求当前未消费量（含冻结和credit），不是历史总额。生产Asset列表/数值未批准，显式规则未配置默认关闭，开发夹具不是生产阈值。
- 真实Fill/费用驱动FIFO消费；更细lot卖出旧零gross残余以认证分配转移原Instrument库存归属，不重复余额/成交或造空仓。退款逆序恢复原费用消费，承接前已付费的退款仅凭唯一原slot建立原周期credit。正常复用及相关费用变化不自动永久锁；真实冻结消费、余额不足、证据缺口与其他安全门槛仍失败关闭。
- 人工freeze/unfreeze沿既有CorePayload.control_command身份/版本/原事实/数量合同；query为residualState。已消费数量不能再冻结，未决卖出、Unknown或费用风险不明拒绝冻结；解除只减少frozen，不删除资产/历史或解除其他门槛。真实Web签名控制到Owner未接线，没有新CLI、自动补买或清理权限。
- 每次生命周期变化追加并pin完整投影承诺，snapshot/replay认证来源、分配、remaining/frozen/version/credit。冻结控制归档后仍可恢复；外层snapshot摘要重算不能掩盖来源/分配篡改。112来源门槛预留16个有界在途槽，覆盖opening及需要残余的聚合sell/amend，纯gross减仓不一概阻断。128边界由State公开接口验证，非Owner128来源端到端或无限partial资格；耗尽后无证明的gross-zero事实保留Canonical及故障，待证未应用。
- 最后聚合卖单资格修补后ReleaseSafe **6/6、退出0**，State模块 **1/1、退出0**；完整09a **22/22**与经济 **6/6**均在完整承诺补强后、最后资格修补前通过。新Python **12/12**已确认；Host退出0、固定轨迹冻结值核对完成，主窗口统一全量ReleaseSafe **724/724、退出0**。详见[生命周期验证](09a-owned-residual-verification.md)及[经济验证](09a-owned-residual-economics-verification.md)。

09a核心能力已resolved；后续生产Asset数值、真实Venue费用凭证与连续运行/认证回收资格未取得，08/09b/09范围和依赖不变。未部署或下单。

### 此前首版范围冻结（已被用户最新方向取代，保留历史）

用户要求冻结首版范围及 Asset 参数。范围现冻结为：只承接 gross lots、OpenCost、margin 精确归零后的正 sub-lot 现货余额；保留原归属且禁止新周期花费；永续、负资产、Unknown 及经济证据缺口继续占用。费用更正采用已验证的独立 FeeAdjustment 合同，不覆盖原 Fill；本票不包含真实 Venue 更正协议资格、已承接残余处置/解锁权限或连续运行认证回收。

Asset 数值尚待用户提供允许资产、单笔上限、累计上限及最大存续时间，不能将开发夹具参数视为用户确认值。累计按同一 DecisionDomain 内相同 Asset 跨账户合计；未列资产默认禁止承接。收到数值后绑定实际 AssetDefinition 身份/版本换算原子数量，并冻结规则版本；在此之前不宣布参数冻结或关闭 09a。

此前两个实现子任务均由 **GPT 6.1 Sol、medium** 子代理在独立工作树完成，主窗口整合及统一验收；没有把子代理定向结果当作全量或生产资格。当时 journal/state/registry 为 **45/49/43**，canonical **16**，StateDigestV13 / SemanticAuthorityDigestV3；下文 44/48/42、707/707 等属于更早零残余首版历史证据。

- 仅 gross lots、OpenCost、margin 精确零且 `0 < atoms < baseAtomsPerLot` 的正现货余额可显式承接。按 Asset 版本化规则提供单次/累计上限和最大存续时间，默认未配置即关闭；规则事实 pin、原规则截止时间、同次两腿累计及有界容量均核对。原账户/VirtualPortfolio/周期/Asset、精确余额和费用账务不变，不转 Treasury、不重复估值、不供同品种或同账户共享 Asset 的新周期花费。永续、负资产、Unknown、未闭合经济/对账/历史证据仍拒绝终结。
- 独立 FeeAdjustment 校验原 Fill/归属、连续费用版本及来源证据，按原币追加差额，跨币种分别冲回/记入；不更改原 Fill、成交累计或 TradingRebate。归档原成交须由 typed fee_origin 认证。旧已承接周期的相关 Asset 费用增减均在合法入账后锁存 OMS recovery-only；退款也不能自动归新周期。真实 Fill 吞掉已保留库存同样先入账、再锁存，原残余记录不改写。
- P2 `af2c8a80` 同步费用更正对 Instrument 现货库存投影的变动，避免 native 总额已变但品种库存仍旧；基础币扣费、退费及随后退出闭合的定向均 2/2。`292bd8f4` 收紧订单历史入口，拒绝只应由 Fill 历史承接的 fee_origin typed key。该入口补丁已由最终统一 717/717 回归覆盖。
- 已确认定向：残余 ReleaseSafe 4/4、容量模块 2/2；费用 ReleaseSafe 5/5、18窗口/36 Fill 归档 2/2及连续资金费窗口 2/2；主树交叉 hook/共享 Asset 两场景加入口 **3/3**。主窗口已确认 Python **12/12**、真实 Host 集成 **exit 0**。统一全量 ReleaseSafe **717/717，通过，退出 0**；不据此授予生产资格或关闭票。

详见[残余记录](09a-residual-verification.md)、[费用记录](09a-fee-verification.md)、[整合记录](09a-integration-verification.md)。生产 Asset 阈值未冻结、真实 Venue 独立更正凭证尚未取得运行资格；普通 Fill 改 fee 仍是冲突，不能冒充 FeeAdjustment。未建模的 Venue 最小名义额/gross 非零尘埃仍不能承接。已承接 sub-lot **没有人工清理交易或解除保留权限**；不补买、不自动归集。到期保留资产风险并阻止新承接/新周期，不能称自动清理。

09a 保持 **in_progress**；64 个活动加终结身份、最多128个成员残余、16条Asset规则和有界费用修订/账本不构成连续运行容量资格，未做认证回收。08 仍仅 checkpoint 基础设施；09b/09 的依赖和待验收范围不变。未部署、下单或同步 GitHub。

## 历史源码核对与首版合同（2026-10-22）

### 2026-10-22 追加实施授权：残余承接与费用调整

用户在本窗口明确要求实施以下两项优化；这是对先前「仅零残余」范围的追加，不改变 08、09b/09 的待验收范围。两项在独立工作树由 GPT 6.1 Sol medium 子代理实施，定向验证后由主窗口整合，统一执行最终全量回归。

- 正现货尘埃可按显式版本化 Asset 规则承接；未配置规则时仍只允许精确零释放。承接保留原账户、VirtualPortfolio、周期、精确数量及费用归属，不改变经济余额或重复估值；残余不可供新周期花费。单笔和累计上限、最大存续时间及容量必须校验，开发夹具数值不是生产阈值批准。永续残仓、负资产、Unknown 和经济证据缺口继续保持占用。后续处置使用已有核心意图和明确权限，不新增补买或自动归集权限。
- 新增独立的费用调整事实，引用原 Fill、来源更正证据及原费用版本，由核心计算原币差额并追加账务；跨币种冲回旧币种、记录新币种。原成交内容、唯一经济成交累计及 OMS 报告累计不变；费用和返佣保留各自语义。同身份同内容幂等，异内容冲突，缺证据或版本不符拒绝，不能因新事件存在而清除既有经济故障。未被适配器证据合同支持的 Venue 继续失败关闭。
- 公共验收沿用下文已约定的 VenueAdapter → TradingShard.apply → Owner/Store、快照和重放接缝。覆盖成功入账、对账后闭合、旧周期/归档身份、重复冲突、账户隔离、承接额度与可用余额，以及 append/commit/checkpoint 故障。

本节及以下各节保留追加授权时与此前零残余首版的历史记录；当前支持、格式及验收状态以上方 2026-10-23 整合状态为准。

基线 HEAD：`53a91973`；检查时工作树无修改。

- `src/trading/cycle_occupancy.zig`：64 个周期、每周期最多两个成员；支持检查、建立和校验，没有终结或释放路径。
- `src/trading/trading_shard.zig`：`admitDomainGroup` 在同一候选内建立占用并绑定命令证据；`cyclePinsOrder`、`commandNeedsDispatchFacts`、`checkpointPins` 保留活动周期依赖。`validateSnapshotStateInner` 核对占用事实及配置，canonical digest 包含完整周期记录。
- `src/runtime/demo/demo_authority.zig`：活动周期阻止 Fill 归档；不能为了释放容量直接取消这个保护。
- `src/execution/execution_gateway.zig`：发送证明查询原周期。释放后仍需处理历史命令的证明及迟到事实，不能把已终结周期当成可发送许可。
- `src/runtime/recovery_cutover.zig`：现有 `RecoveryCoordinator.expectedVenueEvidence` 使用固定 settlement asset 和 spot/swap 汇总；订单证据虽覆盖驻留订单，仍不足以证明多账户、多 Asset 周期闭合。
- [08](issues/08-deterministic-checkpoint.md)明确仅完成 checkpoint 基础设施；真实模型运行及确定性待验收，整票仍阻塞 09b。

## 首版已确认的两项合同（历史范围，后续授权已扩展）

1. **残余释放政策**：建议首版只允许数量精确归零的周期释放。任何非零现货残余仍留原 VirtualPortfolio/账户/Asset 账本并保持占用；永续仓位也必须归零。此方案不实现允许非零尘埃释放的资格，不能据此关闭原票中非零残余承接的验收项。若需要该资格，须冻结按 Asset 的单笔上限、累计上限、最大存续时间及规则版本，另实现不可再花费的残余承接事实。
2. **08 范围**：建议保留既有基础设施范围，先推进 09a；09b/09 的最终验收继续等待 08。若本次要求关闭整个 09，须补齐 08 的真实模型输入更新、冻结公式和算法/依赖版本，以及运行确定性证据；不能以示例 replay 或 codec 往返替代。

用户已明确批准上述零残余政策及保留 08 范围；批准不代表已取得闭合事实或完成实现。09a 验收按这个首版政策执行，非零尘埃承接释放保持关闭。

## 按依赖实施的路径与当前实现

一次只领取一张票：先 09a；08 与 09a 验收通过后领取 09b；最后逐项核对 09 汇总条件。

09a 在同一 TradingShard 权威内增加显式周期终结输入和事实，不建立第二套锁表。输入引用原策略、周期、配置及可核验经济/对账屏障；核心从自己的订单、唯一 Fill 累计、账户经济投影和认证历史验证条件，不信任调用者的 completed 标志。Unknown、待决报告/Fill 差异、费用/资金费覆盖缺口、Suspense、待查历史、残仓或未承接残余任一存在就保留占用。

终结走既有 Owner candidate → journal append → Store commit → 发布顺序，一次释放全部成员键。保留可认证的终结身份和内容，重复不二次释放；旧身份异内容拒绝；迟到经济事实仍由原订单/账户归属和认证历史处理。不得通过清空余额、OMS 累计、唯一 Fill 累计或历史高水位实现闭合。

实现覆盖周期状态与核心事件/trace、TradingShard apply 与账户投影核对、Owner/Store 事务、快照编码与状态校验、canonical digest、历史 pin/归档边界及公共验收入口。journal/state/registry 为 44/48/42，StateDigestV12、SemanticAuthorityDigestV2；不支持旧持久格式的隐式迁移。四 shard 基准仅在经济断言和三条恢复路径一致后重新捕获。

`TradingShard.qualifyCycleClosure` 生成只读资格；`cycle_closed` 核心输入再次从权威状态计算并逐字段核对，绑定原策略/周期、组内容摘要和两个已提交对账根。检查每个账户的完整经济覆盖、待查历史、经济故障、OMS 恢复锁存、订单终态、预留、独立唯一 Fill 累计及对账时间覆盖；现货/永续的 portfolio/exchange 投影均须精确归零。重复同一终结无新事实，异内容拒绝。Gateway 继续只接受活动周期证明，终结身份不能恢复旧命令发送资格。

终结保留原 Record、完整资格和终结 fact；有界驻留活动与终结身份合计最多 64 个，新准入预留终结槽位，达到上限拒绝新周期，不淘汰原占用或历史。尚无终结身份的认证归档回收路径，不能将此容量称为无限生命周期资格。原周期和终结事实均 pin；订单按原命令中的周期身份 pin，重用账户品种键不重新 pin 旧订单。多账户 Fill 归档改用显式账户键，保持独立已应用累计及原经济归属。

费用内容变化沿用当前 canonical Fill 身份合同：同一 Fill 身份不同 fee 是冲突，保留原账本、持久经济故障并保持占用，不能作为新的成交应用。此处只完成失败关闭验收，**没有实现可接受的费用更正事件、成功更正入账或更正后闭合资格**；不得据此宣称原票费用更正能力已经全面验收。非零残余同样只保留原账本和占用，没有开放尘埃承接释放。

09b 在上述核心事实与 08 的真实策略状态之间接通恢复；按账户及 Asset 核对证据，完成 cursor 追赶、新 HostActivationBarrier 和原周期关联。保留原期限、退出锁存及下一意图身份；恢复本身不授予新开仓，不重发历史意图。Keep/Migrate/Rebuild 与 Successor 必须逐项证明经济事实不重置。

## 已有任务约定的测试接缝

- VenueAdapter 公共规范输入 → TradingShard.apply → Owner/Store：报告/Fill 两种顺序、重复/迟到、费用更正、资金费、账户对账与认证历史覆盖；观察账本、唯一经济累计、占用和拒绝原因。
- 同一持久输入路径：Unknown、永续残仓、非零现货余额、未解决引用均拒绝终结；订单终态释放资金仍保留键。完整闭合后竞争组才能重新占用全部键。
- 终结 append/commit、发布前后与 checkpoint/关闭重开：恢复为旧占用或完整新终结，无半释放；重复承接/终结无额外经济结果；容量、溢出和历史回收不驱逐未解决证据。
- 真实 ManagedHost checkpoint/BeginRecovery → 核心权威追赶 → activation：覆盖 09b 各阶段与 S6 向量；真实模型缺失时只记录未验收，不用人工填写私有字段冒充运行证据。

验证命令、实际结果及尚未验收项见 [09a 验证记录](09a-verification.md)。Standards/Spec 双轴复审后的实现与文档一起提交；未部署或下单。
