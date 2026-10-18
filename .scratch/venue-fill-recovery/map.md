# Venue 成交与恢复安全收口

Label: wayfinder:map
Status: closed

## Destination

把 OKX Demo 在线链暴露的成交顺序、重复记账、批次中断、对账状态和清理风险转换为完全离线、
确定性且失败即停的本地回归。所有 Venue 私有事实继续由 `VenueAdapter` 翻译为
`CanonicalEvent`，再由同一 `TradingShard`、`DurableStore`、snapshot/replay 和
`CanonicalStateDigest` 路径验证，不在 Demo runner 或核心中引入 OKX 特判。

## Definition of done

- OMS 的累计成交只表达 Venue 报告事实；经济投影独立且幂等地记录实际应用的唯一 Fill。
- report、Fill 与 reconciliation 的到达顺序不改变最终权威经济状态，重复事实 no-op，冲突事实失败关闭。
- 脱敏 OKX 私有 fixture 贯通 `ingestPrivateWs`、`VenueAdapter.tryDrain`、Owner、TradingShard、持久化及重放。
- 批次任一点中断后都能从持久事实确定性恢复，不丢尾部、不重复记账、不自动重发外部效果。
- Reconciler 和 Demo runner 的正常、容量、断线、Unknown、清理及重启路径形成固定离线回归。
- Binance、Bybit 与 SimulatedVenue 通过同一 `VenueAdapter` 成交恢复合同，不复制 Venue 专用核心逻辑。
- Debug 与 ReleaseSafe 连续三轮一致，Linux ReleaseSafe 离线工件、格式检查和独立复审均通过。
- 本地证据只追加到现有 OKX Linux 资格票；该票保持开放，本波不执行或授权线上写测试。

## Rules

- 每次只认领并完成一张 Frontier ticket；阻塞关系按 Route 执行。
- 沿公共 seam 测试，不直接测试私有 helper，不通过交换 fixture 顺序掩盖状态所有权错误。
- `VenueAdapter` 拥有 Venue 私有协议到 `CanonicalEvent` 的翻译；Demo runner 不翻译 OKX 私有事件。
- 不删除 overfill、身份冲突、checked arithmetic、SafetyGate 或 replay no-send 保护。
- 权威状态结构变化必须提升 `StateSchemaVersion`；旧状态失败关闭，不增加兼容猜测或迁移层。
- 优先复用现有合同、fixture、故障注入和验收入口，不建设第二套核心、runner 或测试框架。
- 本地图只产生离线证据；Demo、Testnet、生产写入仍需当次 SystemOwner 明确授权。
- 保留现有工作树中的无关改动；不默认同步 GitHub Issues。

## Route

1. [分离 Venue 累计成交与已入账 Fill](issues/01-separate-reported-and-applied-fill-quantity.md)
2. [闭合 Reconciler 状态转换与容量边界](issues/02-close-reconciler-state-and-capacity.md)
3. [贯通 OKX 私有事实到权威状态](issues/03-integrate-okx-private-facts-through-core.md) — resolved
4. [证明批次中断后的确定性恢复](issues/04-prove-adapter-batch-crash-recovery.md) — resolved
5. [用假 transport 闭合 Demo runner 生命周期](issues/05-close-demo-runner-lifecycle-offline.md) — resolved
6. [固定 report、Fill 与 reconciliation 的顺序不变量](issues/06-prove-private-fact-order-invariants.md) — resolved
7. [把成交恢复合同推广到所有 VenueAdapter](issues/07-extend-fill-recovery-contract-to-all-venues.md) — resolved
8. [封存本地放行证据](issues/08-seal-local-release-gate-evidence.md) — resolved

## Frontier

- 无；全部 8 张票据已 resolved。

## Decisions so far

- 2026-09-22：SystemOwner 确认采用 8 张 tracer-bullet ticket；01 与 02 可并行开始，其余按显式阻塞边推进。
- Venue 累计报告不直接产生经济账变化；overfill 以已应用的唯一 Fill 总量和当前 Fill 数量判断。
- 2026-09-22：01 已完成。Projection 持久化唯一 Fill 的订单身份与已应用数量；schema 16 / registry 13，旧快照失败关闭。
- 2026-09-22：02 已完成。reconciliation 结果整组在容量足够时才消费 pending，容量不足保留原顺序待下一次 drain。
- 不把批次处理贸然改成整批原子事务；先证明现有逐事实提交模型可以安全恢复。
- 先以固定表驱动排列建立回归，再补最小有界 fuzz；随机结果不能替代固定证据。
- 多 Venue 验收复用现有共享合同，不新增通用插件框架或 Venue 专用核心分支。
- 2026-09-22：03 已完成。私有 raw fixture 贯通 Owner、持久化与重放；结算资产使用共享 canonical identity，且对账屏障优先保留 REST bill provenance，使 WS/REST 逆序输出相同私有事实。
- 2026-09-22：05 已完成。Demo runner 的离线 fake transport 固定验证 not-sent/submitted/Unknown、no-write replay 与未武装拒绝；买入和清理共用权威观察判定。清理出现 Unknown、残余风险或挂单时锁存账户 Gateway，且离线结果不提升任何 Demo/Linux/production 资格。
- 2026-09-22：06 已完成。固定四种合法 report/Fill 到达排列、32 个固定种子的有界变体，以及 cancel/reconciliation 后迟到 Fill 均保持相同 `SemanticAuthorityDigest`、不同有序 `CanonicalStateDigest`，且 replay 无外发；冲突 Fill 身份失败关闭。现有 checked-arithmetic 极值回归与该矩阵同套执行。
- 2026-09-23：07 已完成。共享 `VenueAdapter.tryDrain` 成交恢复合同覆盖 SimulatedVenue、Binance 与 Bybit 的实际 canonical partial-Fill batch、身份/账户范围和归一化 fee/rebate；Unknown 仅经 reconciliation 解除。三者的 Debug/ReleaseSafe 离线矩阵均通过，未增加 Venue 专用核心路径或任何网络写入。
- 2026-09-23：08 已完成。三轮 Debug 与三轮 ReleaseSafe 根矩阵均为 264/264；Linux x86_64 ReleaseSafe 仅编译工件通过。机器可读 barrier/digest/no-send 摘要已封存，且仅追加本地离线证据到既有 OKX Linux 资格票；所有在线资格保持不变。

## Acceptance gap baseline

2026-09-22 scoped review compared the remaining tickets with the current source and root suite. Existing
unit/module tests are reusable evidence only; they do not close the following missing public-seam matrices:

| Ticket | Current reusable evidence | Missing closure work |
| --- | --- | --- |
| 03 | OKX `ingestPrivateWs -> tryDrain` canonical output; Owner and shard unit tests | One offline raw orders fixture through Owner, DurableStore, snapshot and replay, including full/two-partial fills, fees, duplicate/conflict and REST/WS reversal |
| 04 | DurableStore faults and shard replay in isolation | Adapter batch crash points across raw ingress, report, Fill, balance and store barriers; restart digest/no-send assertions |
| 05 | Demo policy, gateway and adapter unit tests | Programmable fake-transport lifecycle/restart matrix, cleanup outcomes and SafetyGate assertions |
| 06 | Applied-Fill accounting, semantic digest, fixed four-row permutation matrix, 32-case seeded fuzz, cancellation/reconciliation and checked-arithmetic regressions | Closed 2026-09-22; no remaining local acceptance gap |
| 07 | Per-venue lifecycle/private-parser tests and shared canonical Fill/recovery contract | Closed 2026-09-23; no remaining local acceptance gap |
| 08 | Three Debug/ReleaseSafe repetitions, offline Linux artifact, machine-readable evidence and append-only Linux qualification note | Closed 2026-09-23; local-only evidence does not qualify online execution |

### Digest decision for 06

Accepted 2026-09-22 in [ADR 0009](../../docs/adr/0009-separate-semantic-authority-digest-from-audit-trace.md):
retain `CanonicalStateDigest` for Trace and snapshot integrity, and compare a separately named
`SemanticAuthorityDigest` for legal private-fact permutations. It excludes arrival-order evidence but does not
replace the canonical digest, snapshot identity, dispatch authority, or conflict checks.

## Reused evidence

- [Linux 生产资格收口](../production-readiness/map.md)
- [OKX Linux 在线资格票](../production-readiness/issues/05-qualify-okx-linux-online-chain.md)
- [主安全修复波次](../main-safety-remediation/map.md)
- [核心领域词汇与不变量](../../CONTEXT.md)
- [Venue seam 决策](../../docs/adr/0001-separate-venue-execution-and-market-feed-seams.md)
- [DurableStore 持久化合同](../../docs/adr/0004-durable-store-persistence-contract.md)
- [权威安全状态 schema 决策](../../docs/adr/0006-authoritative-safety-state-schema-9.md)

## Not yet specified

- 若本波引入新的权威持久状态，具体下一个 `StateSchemaVersion` 与相关 registry 版本由 01 在核对当前源码后确定。
- 独立复审人员、Linux 离线验收节点和最终证据 revision 在 08 执行时记录，不能预先伪造。

## Out of scope

- 任何 Demo、Testnet 或生产在线写入，以及真实资金清理。
- 关闭或提升现有 production-readiness 票 05、Linux 资格或 ProductionQualified 状态。
- 新增 Venue、产品类型、Smart Order Routing、通用 transport/plugin 框架或第二套控制面。
- 以本地测试证明不存在所有 bug，或把 Windows/离线结果解释为 Linux 在线或生产资格。
