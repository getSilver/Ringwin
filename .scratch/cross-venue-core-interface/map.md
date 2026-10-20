# 跨所策略核心接口任务

Status: open

来源：[三项核心接口交接 spec](../cross-venue-arbitrage/issues/02-core-interface-handoff.md)。
用户于 2026-10-20 确认以下 10 张任务的拆分与依赖。本地图只发布任务，不表示实现、架构决策或运行资格已通过。

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
- 不修改或关闭来源 spec；当前授权为任务发布。实现、部署、真实或 Demo 交易不在本次操作范围。

## Route

| 任务 | Blocked by | 归属 |
|---|---|---|
| [01 权威边界](issues/01-authority-boundary.md) | 无 | H2/H3 设计前置 |
| [02 双边深度快照](issues/02-depth-snapshot.md) | 无 | H1 |
| [03 增量与重同步](issues/03-depth-resynchronization.md) | 02 | H1 |
| [04 Host 完整组](issues/04-host-intent-group.md) | 无 | H2 |
| [05 共同准入与占用](issues/05-joint-admission.md) | 01、04 | H2/H3 |
| [06 双 IOC 执行](issues/06-dual-ioc-dispatch.md) | 05 | H2 |
| [07 原生 Post-only](issues/07-native-post-only.md) | 05 | H2 |
| [08 确定性 checkpoint](issues/08-deterministic-checkpoint.md) | 无；最终验收需确认策略 schema | H3 |
| [09 周期恢复与激活](issues/09-cycle-recovery.md) | 05、08 | H3 |
| [10 综合验收](issues/10-public-seam-acceptance.md) | 03、06、07、09；相关策略行为与参数合同冻结 | H1/H2/H3 |

## Frontier

- [01 确认跨账户共同准入与周期占用的权威边界](issues/01-authority-boundary.md)：in-progress；源码核对与设计提案已形成，待架构及追加拆分确认。
- [02 双边多档快照贯通策略输入](issues/02-depth-snapshot.md)
- [04 Host 完整 IntentGroup 原子传输与身份校验](issues/04-host-intent-group.md)
- [08 版本化策略状态与确定性 checkpoint](issues/08-deterministic-checkpoint.md)：可开始接口核对和设计，最终验收受 schema 确认门槛约束。

## Decisions so far

- 2026-10-20：01 的 [权威设计提案](authority-design.md) 与 ADR0017 已形成，均为 proposed；建议单 owner 多账户共同提交，尚未接受架构、发布追加切片或解除 05/09 阻塞。现有源码与离线测试不构成双账户共同准入证据。
- 已批准 10 票拆分与阻塞边；01 是设计前置票，其余按可独立验证的行为交付。
- H2 占用与 H3 恢复共用唯一权威设计，不各建一套锁表。
- Host 完整组传输可以独立验证，但不能据此授予共同准入或发送权限。
- Post-only 优先复用已有规范语义，核对 Host 至适配器的完整传递，不重复创造类型。
- 模型状态编码与恢复一致性独立开展；与核心占用事实的最终联结归 09。

## Not yet specified

- 跨账户/shard 的最终权威边界、提交与路由方案，待 01 证明并确认。
- 双边深度容量、格式身份与兼容策略，待 02/03 形成证据。
- 最终策略状态 schema、数值 codec 与支持平台的确定性证据，待 08。
- 相关策略行为、参数合同及模型版本的冻结证据；文档成文不自动等于冻结。
- Venue 与模式运行资格、实际参数校准及线上验证授权。

## Out of scope

- 改写策略公式、扩大交易权限、选择部署资金与账户名单。
- GitHub 同步、生产部署及未另行授权的真实或 Demo 交易。
- 把 L2 深度当作 maker 队列位置、成交率或收益证据。
- 本任务集通过即宣称完整策略或生产资格通过。
