# 08：策略 checkpoint 实现合同提案

日期：2026-10-21。状态：proposed，等待策略 schema 确认；不是功能完成或数值资格证明。
归属：[08](issues/08-deterministic-checkpoint.md)。语义依据：[S6](../cross-venue-arbitrage/state-recovery-contract.md)、[S4](../cross-venue-arbitrage/parameter-contract.md)，所有权遵守 ADR0007、ADR0017。

## 当前源码核对

| 公共路径 | 当前行为 | 本票缺口 |
|---|---|---|
| `src/strategy/strategy_host_recovery.zig`：`encodeCheckpoint/decodeCheckpoint` | QSSC V1，192-byte header，payload 最多 8 MiB，CRC32C 和 SHA-256；元数据绑定实例、定义、配置、schema、cursor 和下一序号 | `PortableState` 只有 accumulator/event_count；没有真实策略字段或模型依赖校验 |
| 同文件：`Recovery.begin/applyBatch/finishRecovery/authorize` | 有界示例事件、无权重放、序号推进、屏障及摘要检查 | 9-byte delta/emits 输入不是模型或周期规范输入；示例一致性不证明 S6 |
| `python/strategy_host.py`：`decode_checkpoint/state_digest/apply_replay_batch/recovery_once` | Python 实现相同示例；BeginRecovery 后追赶、报告、等待激活，再处理输入 | 固定两字段解析与更新；没有完整策略状态或反向 checkpoint 内容发布 |
| `src/strategy/strategy_host_lifecycle.zig`：`ManagedHost.beginRecovery` | 把 checkpoint 送给真实 Python Host；supervisor 校验会话和恢复报告 | 需要反向快照请求/响应以及发布成功与否的完整公共路径 |
| `src/runtime/recovery_cutover.zig`：`catchUpPublishedStrategy` | 接收调用者提供的候选容器，按 cursor 降序选择，使用示例 replay | 候选类型的名称不能证明 checkpoint 已由 Host 发布并持久提交 |
| `src/testing/integration/strategy_host_recovery_integration.zig` | 真实 pipe、示例恢复摘要、输出 fencing | 不是滚动窗口、AR(1)、协方差或待成熟标签的运行证据 |

当前没有把以上示例称为已实现的 H3。来源 S6 也明确声明最终字段与数值方案尚未完成实现确认。

## 建议确认的 schema 范围

建议一次确认 **S6 第 2–4 节全部字段语义**，实现独立的跨所策略私有状态 schema 1，保留现有示例 schema 的明确身份，禁止把旧两字段状态自动解释为新状态。继续使用 PortableStrategyStateJsonV1，业务 schema 身份/版本与容器版本分开。

固定字段顺序为 `dependencies, progress, pairs, research`；每个对象都有固定字段集合，不开放任意扩展字典。数组顺序明确：配对按配置中稳定 pair_ref 排序，订单引用按业务身份排序，模型窗口按有效网格顺序，标签按生成 cursor/预测身份排序。反序或重复身份拒绝，不能在恢复中自行排序修正输入。

| 分组 | 必需状态与 tag | 交叉验证 |
|---|---|---|
| dependencies | 数值 codec/算法版本，配置、模型、校准、执行模型、规则及资产版本的不可变内容引用 | 与预期依赖清单精确匹配，解析不到内容或哈希不符即拒绝 |
| progress | 最后完整应用输入身份及版本；cursor/next IntentSequence 在容器元数据中为唯一编码 | 所有证据 cursor 不得越过容器 cursor；实例/定义/配置/schema 全部绑定摘要 |
| pairs：周期 | pair_ref、两腿账户/Instrument、方向、阶段、Reconciling 前阶段、原组及核心周期引用 | 一配对一个活动周期；恢复只核对核心引用，不生成或释放核心占用 |
| pairs：计划 | 原数量及单位、模式、Pi_reference、TP_entry、alpha、绝对下限、退出政策引用 | 存量周期版本冻结；不得用新模型或配置重算目标 |
| pairs：持仓目标 | `pending` 或 `frozen`；frozen 有 q_matched 证据、TP_holding、冻结 cursor/规则引用 | pending 不携带冻结字段；Holding 必须 frozen；只冻结一次 |
| pairs：执行和经济 | 原/替代/对冲/修复/退出意图引用、次数、已观察 Fill/终态 cursor、Unknown 引用 | 不保存可写余额、风险额度或预留表；首版省略可选经济缓存，只保留可认证来源引用 |
| pairs：异常和时间 | 首次退出原因/序号、附加原因、首次预留/发送/成交引用、预测/执行/持仓/退出/修复期限及来源时钟证据 | Exiting 不回 Holding，期限不延期；不跨机复用单调时钟；原始原因不被新原因覆盖 |
| pairs：信号 | 冷却及闭合证据、方向/score 版本、最近网格、重置/越阈值计数、机会 tag、身份元组、固定 deadline、评估次数及请求/消费状态 | no_opportunity 无活跃 deadline；机会 trigger 使用 ShardSequence；未决请求不能恢复为新机会 |
| pairs：模型 | `rolling` / `ar1` / `state_space`，预热阶段、最后输入和网格、完整窗口及缺口；AR(1) 参数引用/最后观测；状态空间 filtered 均值/协方差/更新阶段/先验 | 不能清窗口、重新拟合或装入 smoother 终值；tag 对应字段必须完整 |
| pairs：监测和标签 | Normal/Warning/InvalidLatched、原因及恢复证据、窗口身份/进度/连续计数；预测身份、生成 cursor、到期、h、版本、预测区间、标签状态 | 未成熟/缺失不计成败；同窗口不重复；解除一种原因不清其余锁存 |
| research | 生成器/算法版本、固定随机材料、评估身份与已用预算 | 恢复不换 seed、不多消费或补领研究额度；禁用分支显式标记 disabled |

核心周期引用的实际编码与校验归 09；08 应定义带类型和版本的关联槽及未解析状态，未解析不能解释为没有占用或已闭合。若 09 改变引用结构，必须显式版本化，不能默默改 schema 1。

## 数值 codec 提案：无损 binary64 组成字段

建议模型中间状态采用命名版本 `binary64_bits_v1`：有限 IEEE-754 binary64 的原始 64 位编码为 **16 个小写十六进制 ASCII 字符**。JSON 中不出现浮点 token；严格拒绝 NaN、Inf、非规范长度/大小写和错误 tag，保留有符号零与 subnormal，不在 checkpoint 时另行量化。这个 codec 只用于模型统计状态，不用于经济金额、订单数量、目标或身份。

经济值继续用明确 Asset/Instrument/rules 引用及整数 atoms/ticks/lots；金额按 i128、身份按既有 u128、cursor/计数按 u64 范围检查，ppm 在各自语义区间检查。精确有理量分母为正，约分后规范编码。整数只以规范十进制 JSON integer 编码，用 Python 整数和 Zig 指定位宽解析，不通过 binary64。S4 的向下收益、向上成本/目标及门槛规则保持精确整数/有理数运算。

运行规则必须另以数值算法版本绑定：固定逐标量操作顺序，不使用依赖线程/批次的归约，不使用 BLAS 自动并行或隐式 FMA。模型状态每次更新完成后即满足同一 codec 的有限值与维度约束；不能只在保存时检查。协方差的维度、对称性、非负方差与半正定性要显式校验，不能用“数值误差允许”为负方差开例外。

该选择保留现有模型数值而不引入未经校准的定点 scale；**无损编码不保证运算跨平台相同**。先取得实际 Windows x86_64 / 精确 CPython 构建的连续运行证据；Linux 和其他 Python/数学库组合为 not_run，直到同输入比较通过。不能把某模型的通过推广到另外两个模型。

这是待确认方案，尚未冻结模型更新公式或取得数值资格；公式及依赖版本须进入测试清单，不通过就不能关闭 08。若改为定点，需另定义每个原始算术步骤的 scale、溢出与舍入，并重新验证连续更新边界，不能只换序列化器。

## 容量提案

建议首版采用以下硬上限；它们是可实现范围，不是实盘部署参数：

| 对象 | 建议硬上限 | 达限行为 |
|---|---:|---|
| 每实例配置配对/活动周期 | 16 / 16 | 新配对或新周期拒绝；已有周期不驱逐 |
| 每周期订单/意图关联 | 64 | 停相关新增风险，保留未决引用 |
| 每配对滚动/诊断窗口 | 3,600 个观测 | 正常固定窗口只按已定义滚动规则更新；恢复不裁剪 |
| 每配对待成熟标签 | 256 | 拒绝新增预测，不能删除未成熟标签腾位 |
| 状态空间维度 | 2（中心及偏离） | 其他维度使用新 schema，禁止截断矩阵 |
| 每配对异常原因 | 16 | 原因用明确枚举和唯一集合，超范围拒绝 |
| 完整 payload | 8 MiB | 编码前/解析前检查；任何字段总量仍受总字节预算约束 |

各字段上限同时受 8 MiB 总量限制；实现必须给出最大合法实例编码预算和内存预算，不能声称各局部上限组合一定可装入。不接受依赖无界 Python 容器后才发现总量超限的实现。观测记录、引用及字符串的单项字节上限也须在实现 schema 表中逐字段声明。

## 发布与恢复接线

1. 复用既有匿名 pipe framing，新增显式版本化 checkpoint 请求/响应；请求绑定当前 session、activation、策略、cursor 与请求身份，响应不得任意指定路径。
2. Python 只在完整输入的确定更新边界编码；一个请求返回一个完整有界容器。Zig 在接收边界验证会话、请求、schema、精确 cursor、依赖、内容身份及 StrategyStateDigest。
3. 内容经既有 DurableStore 所有者持久保存后，再持久提交 StrategyCheckpointPublished 引用；未提交引用不用于恢复、不报告发布成功。内容保存成功但事实提交失败只产生未引用内容，不提升恢复资格。
4. 具体对象承载复用 DurableStore 可提供的合同；不得自行绕过 Store 写路径，也不把 8 MiB 内容塞进 canonical event。若 Store 需要扩展对象 API，先声明其容量、保留和提交合同。
5. 恢复只选择当前已提交且兼容的发布引用，从该 cursor 无权重放到指定屏障；缺日志尾、依赖缺失或内容损坏拒绝激活。重放推进同一 IntentSequence，但不发布历史交易意图。
6. 保留现有当前 HostActivated 和核心权限检查；08 不授予新开仓权限。核心占用/周期对账与最终激活联结由 09 完成。

容器仍可承载 PortableStrategyStateJsonV1，但新增控制消息、业务状态身份及必要 canonical 发布事实必须各自显式注册；核对当前 registry/journal/state 版本后决定实际升级，不能在设计阶段填一个未经验证的未来版本号。

## 已由任务指定的测试接缝

- 真实 `ManagedHost` 输入、checkpoint 请求/响应及 BeginRecovery：比较连续执行、不同批次、多个切点恢复后的完整规范 bytes、StrategyStateDigest、下一序号与意图业务内容。会话/batch 授权包络允许不同，不能因此忽略业务差异。
- Host → Zig → DurableStore → 发布事实提交 → 关闭重开恢复：证明内容和发布引用绑定；注入写内容、提交事实及恢复读取故障，不能使用未提交 checkpoint。
- 非法输入和容量从以上公共边界输入：重复键、未知字段/tag、矛盾状态、非法数值/矩阵、过大窗口/标签、错误 schema/hash/依赖/旧会话均明确拒绝。

覆盖 S6-A/B/J/M、L/O 编码部分。每个模型分别记录预热/窗口、标签成熟与随机材料跨切点的连续性；边界向量含 tick、ppm、TP atoms 的恰好相等及上下一个单位，真实决策路径不能用 would_emit_intent 布尔示例替代。TDD 按一条公共行为红绿实现，不针对私有辅助函数补镜像测试。

## 实施顺序和确认门槛

1. 确认本提案的字段范围、codec、容量和公共接缝；记录用户确认消息及最终合同版本作为 schema 确认依据。
2. 一条真实模型状态的 Host 输入→checkpoint→恢复 tracer，先失败再实现；随后补齐模型分支、信号/监测/标签及冻结计划的不变量。
3. 接通发布持久路径和错误/容量边界；09 的核心联结继续保持未通过。
4. 运行定向测试、完整测试和 Host 产品验收；按实际平台记录 S6 向量，进行 Standards/Spec 双轴审查后提交实现。

当前仅完成源码核对和可审阅提案。所有 08 完成条件仍未勾选；未有用户确认、实现、运行和审查证据前，不将本提案当作已冻结 schema，不关闭任务。
