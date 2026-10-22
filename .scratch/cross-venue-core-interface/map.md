# 跨所策略核心接口任务

Status: open

来源：[三项核心接口交接 spec](../cross-venue-arbitrage/issues/02-core-interface-handoff.md)。
用户于 2026-10-20 确认原 10 票拆分，并在 01 设计审查后确认 ADR0017 及 05a/05b、09a/09b 追加拆分。01 已完成；05/09 保留为汇总验收。架构确认不表示功能实现或运行资格已通过。

## Destination

补齐 H1 双边深度、H2 Host 完整双腿输出与共同准入、H3 周期和模型恢复，以公共接缝证明核心对跨所策略的支持。

## Definition of done

- H1/H2/H3 分别具有明确的数据、所有权、错误、容量和兼容合同。
- 必要的领域与架构决策经过确认；Python 不取得权威交易状态所有权。
- 公共接缝、持久提交及恢复故障验收附实际命令、结果、版本与局限。
- I1–I8、S6-A–P 逐项有证据或明确未通过原因；未通过项不得关闭相关交付。
- 完整组传输、核心共同准入、各 Venue 执行及各模式资格分开记录。

## Rules

- 使用本地 tracker；每次只认领一张无未完成 blocker 的任务。ready-for-agent 表示任务已可供领取，不取消 Blocked by。
- 开工前重新核对当前源码、工作树、GLOSSARY 与相关 ADR；不得把交接中的缺口描述当成当前实现事实。
- 遵守 ADR0001、0007、0014 以及涉及的持久历史和恢复约束。新权威所有者、跨 shard 协调及难逆格式决策必须先确认取舍，再记录领域决策。
- MarketFeedAdapter 拥有公共行情转换，VenueAdapter 拥有私有事件转换；核心拥有授权、资金、风险、预留、命令和唯一经济成交。
- 每张实现票都包含公共路径、错误/容量边界及相应持久恢复验证，不能把全部测试推给最终综合票。
- 不新增追踪止盈、追加仓位、Unknown 自动重发或延长持仓等策略权限。
- 不修改或关闭来源 spec。01 的设计交付与架构/拆分确认已完成；其余票仍须逐票领取并验收。本地图不授权部署、真实或 Demo 交易。

## Route

| 任务 | Blocked by | 归属 |
|---|---|---|
| [01 权威边界](issues/01-authority-boundary.md) | 无 | H2/H3 设计前置；resolved |
| [02 双边深度快照](issues/02-depth-snapshot.md) | 无 | H1 |
| [03 增量与重同步](issues/03-depth-resynchronization.md) | 02 | H1；resolved |
| [04 Host 完整组](issues/04-host-intent-group.md) | 无 | H2；resolved，完整传输与身份入口 |
| [05 共同准入与占用](issues/05-joint-admission.md) | 05a、05b（均已完成） | H2/H3 汇总；resolved，离线核心验收 |
| [05a 多账户权威表示](issues/05a-multi-account-authority.md) | 01（已完成） | H2/H3；resolved |
| [05b 共同准入与占用](issues/05b-joint-admission-occupancy.md) | 01、04、05a（均已完成） | H2/H3；resolved |
| [06 双 IOC 执行](issues/06-dual-ioc-dispatch.md) | 05 | H2；resolved，离线执行接缝验收 |
| [07 原生 Post-only](issues/07-native-post-only.md) | 05 | H2；resolved，离线原生 Post-only 接缝验收 |
| [08 确定性 checkpoint](issues/08-deterministic-checkpoint.md) | 无；最终验收需确认策略 schema | H3 |
| [09 周期恢复与激活](issues/09-cycle-recovery.md) | 09a、09b | H3 汇总验收 |
| [09a 核心周期闭合](issues/09a-cycle-closure-residual.md) | 05b；最终验收需残余阈值及资产规则冻结 | H3 |
| [09b 恢复与激活](issues/09b-cycle-recovery-activation.md) | 08、09a | H3 |
| [10 综合验收](issues/10-public-seam-acceptance.md) | 03、06、07、09；相关策略行为与参数合同冻结 | H1/H2/H3 |

## Frontier

- [09a 核心周期闭合](issues/09a-cycle-closure-residual.md)：in_progress；用户已批准零残余释放、非零继续占用。零残余终结与持久恢复已实现，成功费用更正及非零承接仍待验收，整票未关闭；见[验证记录](09a-verification.md)。
- [08 版本化策略状态与确定性 checkpoint](issues/08-deterministic-checkpoint.md)：in_progress；schema/codec/容量已确认，用户收窄本轮为 checkpoint 基础设施，真实模型验收保持待定。见[实现合同](08-checkpoint-design.md)及[验证记录](08-verification.md)，不解除 09b 的整票依赖。

## Decisions so far

- 2026-10-22：用户批准 09a 首版仅精确零残余释放，保留 08 基础设施范围，09b/09 待验收。新增核心终结事实、双账户对账覆盖核对、双键原子释放、终结身份保留、周期身份 pin 及显式账户 Fill 归档；迟到旧命令 Unknown 不得借新周期提前释放。最终 ReleaseSafe 707/707、Python 12/12、真实 Host 集成通过。journal/state/registry 为 44/48/42；活动与终结身份合计 64 个，无认证回收时达限拒绝新周期。用户明确保留 09a in_progress，后续确定费用更正身份和证据合同：费用内容变化只取得冲突失败关闭证据，成功更正入账及非零残余承接未实现；见[合同](09-implementation-contract.md)和[验证记录](09a-verification.md)。未部署、下单或取得运行资格。

- 2026-10-22：07 resolved，Host原生Post-only、共同准入/发送能力复核、GTC错配拒绝、能力撤销后的安全撤单及journal/checkpoint/文件恢复已离线验收。最终ReleaseSafe **699/699**，修正场景定向 **3/3**、真实Python Host的GTC/Post-only两种多账户文件恢复及既有路径通过，Python **5/5**和**7/7**通过，双轴复审无遗留发现。用户明确选择沿用版本、规则、会话失效及命令期限，不增加独立TTL；长期未更新的能力声明不会自行到期。见[验证记录](07-verification.md)。实际Venue/模式及完整Maker–Taker资格仍未取得，未部署或下单；journal/state/registry保持43/47/41，活动周期释放仍归09a。

- 2026-10-22：06 resolved，双IOC在回报前独立发送、第二腿部分失败、8个发送持久边界、Unknown不重发与可能量、迟到/重复/撤单途中Fill、显式修复及减仓义务均离线验收。复用现有实现，新增公共接缝与经济消费者证明；最终ReleaseSafe **688/688**、核心定向 **6/6**、真实OKX私有WS及归档恢复各 **2/2**，双轴复审无遗留发现。见[验证记录](06-verification.md)。真实Venue联合网络执行、native maker、完整策略与checkpoint联结仍分别归后续资格/07/09/10；活动周期继续pin，产品多账户入口及deployment/production qualification保持关闭，未部署或下单。

- 2026-10-22：05a → 05b → 05 resolved。完整静态清单、四账户权威分区、显式域根/账户键、Host完整组共同准入、预算与占用、故障恢复及安全容量已离线验收；最终ReleaseSafe **683/683**、定向 **25/25**、真实Python Host文件恢复与Python **5/5**通过，双轴复审无遗留阻断。journal/state/registry为43/47/41，Gateway V9最大证据按编码预算修订为39,210条；见[实现合同](05a-implementation-contract.md)及[验证记录](05-verification.md)。现有控制面尚无完整清单/独立锚点发布合同，多账户产品入口保持关闭，deployment/production qualification=false；09a前不释放活动引用，未部署或下单。

- 2026-10-21：用户明确确认 [05a 实现合同](05a-implementation-contract.md) 的静态完整部署分配清单及显式域级历史命名空间。05a 已领取，依序实施 05a → 05b → 05；确认不等于功能验收或部署授权。

- 2026-10-21：用户要求实施 05。按当前源码核对后形成 [05a 实现合同提案](05a-implementation-contract.md)：现有单账户租约不能充当跨账户全局预算来源，业务历史仍绑定单账户。静态完整部署分配清单的信任来源、显式域级历史命名空间待确认；提案不代表架构已接受或功能已实现，05a/05b/05 保持原状态。

- 2026-10-21：03 resolved，连续有界深度、缺口失效与新快照恢复、捕获重放及九个稳定恢复切点已验证；最终 ReleaseSafe 659/659、Python 5/5，双轴复审无遗留阻塞项。格式 15/13/42/46/40，Host 深度 wire 保持不变；见 [合同](../../docs/depth-resynchronization-contract.md) 与 [验证记录](03-verification.md)。I1 策略全链路和任务 10、其他 Venue 与线上资格仍分别验收。

- 2026-10-21：08 schema/codec/容量获确认；用户随后指定仅完成 checkpoint 基础设施，真实模型验收保持待定。新增显式私有状态、Host 请求/响应和 DurableStore catalog 发布/恢复；ReleaseSafe 653/653、Host 产品验收 16/16 通过，双轴审查修复后无遗留发现。整票继续 in_progress，不解除 09b，见 [08 验证记录](08-verification.md)。

- 2026-10-21：04 resolved，真实 Host 完整组传输、授权校验、原子身份消费及日志/快照/文件恢复通过；ReleaseSafe 652/652、Host 产品验收 14/14。单意图 schema 1 保留，完整组 schema 2，journal/state/registry 为 41/45/39。所有组仍以共同准入未实现整体拒绝，不开放双账户预留或发送；见 [04 合同](04-host-group-contract.md) 与 [验证记录](04-verification.md)。

- 2026-10-21：02 resolved，双边每侧 8 档、显式截断和未知数量、独立 Host 深度输入及稳定恢复已完成离线验收；见 [02 验证记录](02-verification.md)。现有顶部增量撤去多档证据，连续深度归 03；不扩大 Venue、模式或线上资格。
- 2026-10-20：用户确认 [权威设计](authority-design.md) 方案 A 及追加拆分，ADR0017 accepted，01 resolved。首版单 DecisionDomain / TradingShard 拥有多账户分区并共同提交，跨 shard 组拒绝；H2/H3 共用核心周期占用。05a 可领取，05b 等待 04/05a；09a 等待 05b，09b 等待 08/09a。现有源码与离线测试不构成双账户共同准入证据。
- 保留原 10 票编号；05/09 汇总各自 a/b 子票，子票与原验收清单均通过后才关闭汇总票，06/07 → 05、10 → 09 的外部依赖不变。
- H2 占用与 H3 恢复共用唯一权威设计，不各建一套锁表。
- Host 完整组传输可以独立验证，但不能据此授予共同准入或发送权限。
- Post-only 优先复用已有规范语义，核对 Host 至适配器的完整传递，不重复创造类型。
- 模型状态编码与恢复一致性独立开展；与核心占用事实的最终联结归 09。

## Not yet specified

- 多账户核心容量、格式与预算来源已由05a冻结并离线验证；完整清单和独立可信锚点的产品发布接入仍缺失，入口保持关闭，动态租约扩容首版不开放。
- 09a 已冻结零残余释放政策；非零现货残余继续占用。成功费用更正及非零承接事实、终结身份认证回收与连续运行容量仍待验收，09a 整票未关闭。
- 快照、连续深度及重同步已由 02/03 声明并离线验证；已知价格覆盖、8 档及截断后的保守失效限制继续适用。
- 08 的 schema/codec/容量已确认；真实模型的版本、输入更新、不同批次/切点和支持平台运行确定性证据仍待完成。
- 相关策略行为、参数合同及模型版本的冻结证据；文档成文不自动等于冻结。
- Venue 与模式运行资格、实际参数校准及线上验证授权。

## Out of scope

- 改写策略公式、扩大交易权限、选择部署资金与账户名单。
- GitHub 同步、生产部署及未另行授权的真实或 Demo 交易。
- 把 L2 深度当作 maker 队列位置、成交率或收益证据。
- 本任务集通过即宣称完整策略或生产资格通过。
