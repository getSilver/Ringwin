# S4 参数、精度与校准产物合同

状态：规格细化完成，运行参数未校准，schema/校验器未实现。归属：[策略规格](issues/01-strategy-spec.md)；行为依据：[合同](strategy-contract.md)、[S1–S3](strategy-refinement.md)。

本文件定义配置必须表达什么以及如何拒绝不完整配置，不提供实盘默认数值，不授予部署或交易资格。字段名是策略规格字段，不是新增核心类型。使用 GLOSSARY.md 的 ConfigEvent、InstrumentRules、AssetDefinition、CutoverBarrier 等既有概念。

## 1. 配置包与来源

一个可执行配置包必须同时绑定以下身份：

| 字段 | 约束 |
|---|---|
| schema_version / content_hash / ConfigVersion | 内容不可变；哈希覆盖全部有效值、引用及单位，不能仅覆盖文件名 |
| StrategyDefinition / state_schema_version | 与策略代码和恢复 schema 精确兼容；缺字段不能按旧解释器猜测 |
| scope | 明确 VirtualPortfolio、配对两腿 ExchangeAccount/Instrument、方向及获准模式；同基础资产与已批准产品范围必须成立 |
| rules_refs / asset_refs / capability_refs | 指向已生效权威版本，不以文件内自填乘数、精度或“支持Post-only”替代核心资格 |
| model_ref / calibration_ref / execution_model_ref | 各含不可变内容身份、适用范围及证据引用，不能使用运行时自动指向最新版的别名 |
| valid_from_utc_ns / valid_until_utc_ns | 半开区间 `[from,until)`，from<until；这里只声明资格时效，不直接激活配置 |
| activation_ref | ConfigEvent/生效屏障证据；本地文件保存成功不表示已生效 |
| safety_policy_ref | 预先完整的撤单/修复/正常退出/紧急退出政策及当前权限约束，不能借开仓模型失效抹掉存量管理责任 |

每个参数值另有 `source_kind/source_ref`，区分核心权威事实、显式风险配置、研究校准和策略派生值。每次评估保存实际解析后的配置哈希和引用；派生值不能反写上游配置。

重复键、未知字段、非法单位、超范围值、同一范围多个同优先级有效版本、引用缺失或范围不匹配均拒绝该配置。零、缺失与“不适用”三者不同：不适用必须由明确产品/模式分支证明，缺失不得解析成零。

## 2. 单位及精度

| 值 | 表达及比较规则 |
|---|---|
| 现金/收益/费用/预留 | `{asset, atoms}`，整数，精度仅来自 AssetDefinition；金额阈值不得跨 Asset 直接比较 |
| 价格 / 数量 | `{instrument, rules_version, ticks/lots}`；乘数从 InstrumentRules 读取；净基础币敞口用有理数换算，不能修改 gross Fill lots |
| 比例 / alpha / 概率 | 采用整数 ppm，1,000,000 表示1；研究中间值可用更高精度，进入经济判定前按以下方向转换 |
| Edge 门槛 | `min_edge_ppm`，1bp=100ppm；界面可显示bp，判定按整数交叉乘法，不比较显示小数 |
| 期限 / 延迟 / 间隔 | 非负整数纳秒；研究h字段为整数秒，转换为纳秒须检查乘法溢出。0只在字段明确允许时有效 |
| UTC时间 / 单调时间 | 字段显式区分；UTC仅用于有证据的有效期与日边界，不能把跨进程单调时间直接相减 |
| 模型统计状态 | 参数记录数值算法、精度及量化版本；NaN/Inf一律拒绝。恢复编码及误差预算由S6/H3验证，未验证不宣称可交易 |

预测净收益转换为现金原子单位向负无穷取整；预估支出、预留向上取整。概率下界向下、最低概率门槛向上转换为ppm。最低收益金额/Edge门槛也向严格方向转换；禁止先四舍五入再比较。

止盈是最低触发金额，因此 `TP_entry=ceil_atoms(max(TP_abs_min,alpha*Pi_reference))`，`TP_holding=ceil_atoms(max(TP_abs_min,r*TP_entry))`；r用匹配净敞口与原净目标量的精确有理比。此处向上仅保留原公式的最低金额含义，不允许人为抬高目标。经济判定必须使用取整后目标做S3检查。

价格/数量采用原有 OrderNormalizationPolicy 及核心规则；若保守价格、数量或费用舍入后不再满足准入，则淘汰，不自动提高侵略性或增加目标。所有加乘、分母和类型转换检查溢出；计算失败不饱和成最大可用余额或最大收益。

## 3. 参数字典

下表的合法范围是结构约束，不是推荐取值。全部金额上限、风险阈值和时限均须在运行配置或权威引用中落实；模式相关字段只在该模式启用时必填。

### 3.1 风险与资金（显式配置/核心事实）

| 字段 | 单位/范围 | 验证要求 |
|---|---|---|
| allocated_budget_ref / total_cap | 权威分配引用、现金上限≥0 | 不能把真实账户全部余额当策略分配；0不产生购买力 |
| pair_cap / base_asset_cap / venue_cap | 现金或名义金额，明确口径≥0 | 各上限同时检查，不重复扣同一占用，不跨所抵消 |
| cycle_loss_limit / daily_loss_limit / drawdown_limit | 明确Asset与正的金额；比例版另有正分母 | 不以收益搜索改变风险边界；外部资金流调整引用固定 |
| day_boundary_timezone | 显式时区身份 | 日边界可重放，跨日不解除锁存 |
| max_unhedged_exposure / unhedged_duration_ns | 基础Asset或名义金额≥0、正时限 | 包含在途订单可能成交区间，0敞口容忍不是禁用校验 |
| margin_rules_ref / margin_safety_ref / leverage_cap | 权威规则、分档门槛、正比例 | 逐所验证实际设置；不得低于核心安全要求或自动补保证金 |
| repair_loss_cap / repair_funding_cap | 现金≥0 | 0表示无相应额外预算，不允许无限补齐 |
| residual_single_cap / residual_total_cap / residual_max_age_ns | 基础Asset/现金≥0、正时限 | 仅获准现货残余；永续不因小额豁免 |

### 3.2 模型、收益与可达性（研究/校准）

| 字段 | 单位/范围 | 验证要求 |
|---|---|---|
| model_kind / model_parameters_ref | 显式滚动/AR(1)/状态空间版本 | 模型专用参数闭合，不允许用另一模型缺省值拼装 |
| sample_grid_seconds / horizon_seconds | 首轮网格1；h候选300/900/3600 | 研究范围，不是所有配对默认合格；上线只启用获验证版本 |
| window_points / warmup_points | 正整数，统计所需时≥2 | 连续有效样本，不能跨缺口凑足数量 |
| reference_exit_policy_ref / scenario_model_ref | 版本化政策、场景及适用域 | 参考不依赖TP；计划包含S1/S3处置，目标不反馈重算 |
| alpha_ppm | 1…1,000,000 | 随入场版本冻结，运行时不搜索 |
| tp_abs_min / min_plan_profit | 正现金金额 | 分别是固定目标下限、开仓实际计划净收益门槛，不能互换 |
| min_edge_ppm | 非负整数 | 开仓收益/BP按合同严格超过门槛；不是资金效率门槛 |
| p_entry_min_ppm / p_hold_min_ppm | 各为1…1,000,000 | 两种分母分别校准；判定为下界≥门槛，不能在线降低 |
| probability_calibrator_ref / probability_error_ref | 阶段、模式、数量/期限范围及误差版本 | 校准与模拟误差去重，超适用域不能默认延用 |
| min_effective_blocks / min_mature_labels | 正整数 | 含计数方法；模拟条数不能代替独立历史证据 |
| scenario_count / max_nested_evaluations | 有限正整数 | 达容量上限返回不合格，不能跳过持仓前gate |
| reference_buffer_ref / plan_buffer_ref | 独立校准引用 | 参考与实际计划不混用残差，不把预测缓冲记为账本费用 |
| monitoring_policy_ref / gap_rewarm_policy_ref | 版本化状态与统计窗口规则 | S5补齐预警/失效/恢复谓词；缺少完整政策不得启用模型 |

### 3.3 执行与时间（模式独立验证）

| 字段 | 单位/范围 | 验证要求 |
|---|---|---|
| reservation_timeout_ns / entry_timeout_ns / max_holding_ns | 正时限 | 分别从首次预留、首次发单、最早经济成交的既有边界起算 |
| normal_exit_policy / emergency_exit_policy | 价格保护、正时限、有限正尝试数 | IOC，两个政策均须完整，紧急退出不要求盈利、不无限追价 |
| hedge_policy / repair_policy | 价格界限、正时限、非负最大尝试数及损失预算 | repair次数0为禁补齐，不是无限；只补已知残余，不追未发生目标 |
| maker_lifetime_ns / reprice_interval_ns / max_reprices | 正时限、正间隔、非负次数 | 生命周期内不重置时钟，安全撤单不等待间隔 |
| maker_quote_offsets_ticks / reprice_improvement_atoms | 非空有界非负整数集合、非负金额 | 原生Post-only，撤旧核对后替换；缺失只使maker不合格 |
| unknown_query_policy / escalation_timeout_ns | 有界查询调度、正升级时限 | 不以超时授予重发或第三腿权限，风险与预留不因告警消失 |
| allowed_modes / mode_qualification_refs | 显式模式集合及独立资格引用 | 缺少maker证据不扩大到maker；是否使用其他模式仍依已授权集合 |

阶段子期限的实际截止点取自身预算与既有父级硬截止点的较早者。持仓到期触发退出不等于退出已完成；后续未退出风险持续显式存在。配置不能通过把每个子期限都设置为“剩余完整总期限”实现无限延长。

### 3.4 行情、费用、数量与排序

| 字段 | 单位/范围 | 验证要求 |
|---|---|---|
| max_book_age_ns / max_leg_skew_ns | 正时效、非负双腿时间差 | 序列健康与新鲜度共同满足，不能用一个覆盖另一个 |
| required_depth_scope / liquidity_model_ref | 有界双边覆盖声明、数量适用域 | 缺数量或超覆盖不推算全量成交；L2不自动代表队列资格 |
| fee_schedule_refs | 账户/产品/Instrument、角色、扣费Asset、有效期 | Instrument覆盖必须明确指向基础规则；同优先级重叠拒绝 |
| fee_rate / fee_rounding / fee_deviation_policy | 精确有理费率、每笔舍入、偏差度量与限额 | maker身份不明按taker；返佣独立，不用负费率隐藏返佣 |
| funding_schedule_ref / funding_outflow_model_ref | 结算时间与分期支出估计 | 准入逐腿支出相加，未来收入为零；实际收付不改写 |
| valuation_route_ref / valuation_max_age_ns | 既有估值路径、正时效 | 第三币费用缺估值不为零，USDT也不因此改变账本Asset |
| quantity_grid_ref / max_quantity_candidates | 有界比例/深度/最小量边界规则、正数量上限 | 正规化后去重并重算，候选不足/超限不选择非法数量 |
| batch_window_ns / recommendation_ttl_ns | 正时长 | 使用确定事实边界，过期建议重算，不按线程先后排序 |
| occupancy_model_ref / occupancy_quantile_ppm / time_floor_ns | 版本、0<分位数<1、正时长下限 | 真实计划包括等待及对账，未完成样本不能删除以压低占用 |
| max_batch_candidates / max_recalculations | 有限正整数 | 达限输出明确原因，不绕过核心预留 |
| cooldown_ns / signal_rearm_policy_ref | 非负时长、版本化重置谓词 | 冷却结束不等于自动开仓；S5补具体谓词，异常仍须显式恢复 |

## 4. 生效、过期及已有周期

配置加载、资格有效、核心激活是三件事。解析及交叉验证通过后仍需显式启用与 ConfigEvent 屏障；遵守 CutoverDrain/CutoverBarrier，不修改当前活动对象来模拟切换。

每个周期保存入场配置/模型/校准版本、TP_entry、S1所需原数量、固定退出政策、起算事实与截止点引用。新版本用于哪些新候选由激活事实决定；不能覆盖既有周期的目标、模式、亏损边界或时钟。当前核心权限、行情/规则和账户事实仍须实时复核，冻结配置不是绕过当前撤权的通行证。

| 情形 | 新候选/拟进入Holding | 已有周期的处理 |
|---|---|---|
| 未知schema、哈希不符、引用不存在 | 配置拒绝，不生成可执行建议 | 不替换已生效版本；依原计划和当前核心权限管理 |
| 模型/成本/概率证据超适用域、过期或不足 | 相关模式/阶段不合格；持仓前按S3退出 | 已在Holding不新增逐次概率退出；若同时触发既有模型失效/风险规则，按该规则处理 |
| 费用缺失/过期/偏差超限 | 停相关新增风险；费用不按零 | 保留安全撤单/退出，使用预先验证的安全处置规则，不伪造正常止盈估值 |
| 行情失效/缺深度 | 不生成正常信号或可执行收益建议 | 按既有安全流程处置；不能用旧盘口宣布达到止盈 |
| 规则/账户/权限发生变化 | 用当前权威事实重新校验 | 旧冻结参数不授予非法下单；不穿零、不盲发、不抹掉风险 |
| 安全处置参数本身不完整或无有效权限 | 禁止启用该运行配置 | 仅执行仍有证据且获准的安全动作；保留风险、撤单/查询能力范围及告警，不猜参数 |
| 任何时限/预算耗尽 | 不延长、不增加次数 | 未成交或Unknown不清零，进入既定退出/对账/升级流程 |

有效期到期本身只描述该证据不再合格，不擅自创造新的强平理由；它是否同时满足某个既有模型失效谓词，须由完整监测政策明确定义。S5未完成或政策不完整时，不授予模型交易资格。实时安全处置规则依其独立有效证据，不静默使用过期费率或取消价格保护。

## 5. 校准交付清单

| 产物 | 必须包含 |
|---|---|
| 数据清单 | 数据哈希、时间/接收可见性、Venue/产品/环境、深度/队列可观测范围、缺失和截断说明 |
| 研究协议 | 时间顺序训练/校准/验证/保留测试切分、标签成熟和跨界剔除、搜索空间/次数、固定风险约束 |
| 模型包 | 模型结构/参数/初始先验、更新与预热规则、数值方法、代码/依赖版本、适用范围和失败条件 |
| 目标与计划报告 | Pi_reference政策和误差、Pi_plan政策和误差、S1/S2完整路径结果、各成本覆盖与缓冲去重台账 |
| 概率报告 | p_entry/p_hold分开，成熟样本/依赖块数、原始与校准概率、误差余量和覆盖验证、适用桶及证据不足比例 |
| 执行报告 | 两模式独立；数量/深度/延迟/队列联合证据、部分成交、Unknown、修复、退出滑点/耗时、未闭合风险 |
| 参数选择报告 | 风险约束内的完整样本外净收益、回撤/尾损、候选淘汰原因、敏感性；不能只列成功周期 |
| 发布清单 | 所有内容哈希/版本/范围/有效期、待填项、资格结论、明确批准及核心激活引用；无证据项不得写passed |

保留测试失败后修改参数须建立新研究版本与未见测试区间；不得把同一测试重跑挑出的结果标为原始保留测试。参数数值与校准产物没有齐备前，本文字段齐全也只表示规格齐全。

## 6. 可检查向量

| 编号 | 输入 | 预期 |
|---|---|---|
| S4-A | 下界真实值0.6500004、门槛0.6500005 | 下界650000ppm、门槛650001ppm，不通过；显示为65%不能改变结果 |
| S4-B | 正预测净收益1.2345678 USDT，原子精度6；最小收益1.2345679 | 预测1234567原子、门槛1234568原子，不通过 |
| S4-C | TP_entry=8.000001 USDT，匹配1/2，下限2，原子精度6 | TP_holding=4.000001，不截断为4.000000；再作S3检查 |
| S4-D | 参数有效期[from,until)，决策时间恰等until | 新准入资格过期，不自动延长；不由此单独改写Holding退出规则 |
| S4-E | maker队列配置缺失，双IOC配置独立完整 | maker不合格；双IOC仍须在授权集合内通过自己的全部准入，不自动继承资格 |
| S4-F | repair最大次数0，或字段缺失 | 前者禁止补齐；后者配置不完整，不解释为无限重试 |
| S4-G | 新版本将目标/持仓期限改大，旧周期仍活动 | 不覆盖旧周期冻结值；按核心切换合同处理，不延长原周期 |
| S4-H | 规则乘数变化、费用资产不匹配、重复配置键或乘法溢出 | 明确拒绝，不能猜测、饱和或沿用错误单位 |
| S4-I | 概率校准以重复模拟次数冒充独立历史块数 | 证据不合格；不能以增大模拟数量自动解锁 |

这些向量验证配置语义，不代表校验器已存在。[S5信号与监测合同](signal-monitoring.md)已补齐重新武装、同次信号有界重评及监测转换规则，其第8节补充字段是本参数合同的一部分；数值仍待校准。[S6状态与恢复合同](state-recovery-contract.md)已给出schema语义与数值一致性验收要求，具体编码和运行证明待实现；H1–H3由另一会话推进核心接口。S4不新增领域词汇或架构决定，不修改 GLOSSARY/ADR。

本轮检查：七份模块文档的相对文件链接均可解析；用 Decimal 独立复算 S4-A/B/C 及负收益向负无穷取整，结果一致。其余向量是待实现的验收要求，未执行配置校验器、模型拟合或交易测试。
