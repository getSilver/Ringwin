# 02: 让 Canonical Venue 对账推进 OMS

Type: task
Status: resolved
Assignee: Codex
Blocked by: None
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让 Venue 返回的 OrderReconciliationResult 成为关闭 Unknown 和推进订单生命周期的唯一规范事实，并严格区分 FoundLive、FoundTerminal、ConfirmedAbsent 与 Unresolved？

## What to build

贯通一个真实 Venue 对账结果从 CanonicalEvent 到 OMS、SafetyGate、RiskReservation 和后续命令的完整路径。ConfirmedAbsent 只证明原发送未形成 Venue Order；任何证据不完整或字段冲突都保持 Unknown 并锁存 ReconciliationBreak。

## Acceptance criteria

- [x] Canonical 对账结果携带目标 Order、revision、累计/剩余数量、证据范围和适用规则版本，并能确定性映射到 OMS。
- [x] FoundLive 恢复精确 live/partially-filled 状态；FoundTerminal 根据权威终态区分 filled、canceled 或 rejected，不靠数量猜测终态类别。
- [x] ConfirmedAbsent 永远不能产生 filled、Fill 或成交账务；它只关闭对应未形成的发送尝试并按合同处置 reservation。
- [x] Unresolved 保持 Unknown、占用和 latched SafetyGate；重复事实为 no-op，同身份冲突失败关闭。
- [x] Venue canonical 路径与内部恢复路径不再维护两套对账语义；live/replay 的订单状态、占用、trace 和 digest 一致。

## Out of scope

- 改写各 Venue 的网络查询覆盖；真实查询资格仍由各 Venue production-readiness issue 验证。

## Answer

Canonical 对账的通用证据包含查询范围、观察时间、原始证据身份与缺席覆盖；TradingShard 校验证据和 OMS 订单、规则及数量，降级不足或矛盾的结果为 Unresolved。OMS 只允许未有权威报告或成交的 Unknown place 以完整缺席证明关闭，并拒绝迟到报告和 Fill；Canonical report/reconciliation 共用 CCC 确认路径。

## 2026-09-23 复核与重开

旧 Answer 是历史结果，不能关闭本轮缺口。[修复计划 R02-A/R02-B](../review-repair-plan-2026-09-23.md#02canonical-对账)记录缺少严格 absent 证据，以及真实 Canonical report/reconciliation 未触发 CCC replacement。源端必须验证证据后输出通用 Canonical 结果；核心证据不足时保持 Unknown；两种入口须共享 OMS 转换并重新验收。

## 2026-09-23 实施进度（未关闭）

- R02-B：`TradingShard` 的 Canonical report/reconciliation 路径现在调用同一 CCC 确认流程；定向测试覆盖两种 Canonical 终态入口。
- R02-A：移除 OrderReconciliationRequest 中调用方自报的 absent 证明位；OKX/Binance/Bybit 在没有可验证缺席证据时返回 Unresolved，TradingShard 的 Canonical 和 CoreEvent 入口均拒绝无证明的 ConfirmedAbsent 并保留 Unknown/占用。OKX 从实际私有订单报告填入正向结果的数量和终态。
- 离线 `zig test src/main.zig` 与 `zig test src/main.zig -O ReleaseSafe` 在当前改动中均为 267/267（最后的 CoreEvent absent 保护以定向测试复核）。仍缺通用查询范围/观察时间/证据身份、完整缺席证明以及本票要求的 live/replay 证据；因此状态保持 open，不能推进 03/04。
- 当前 `Oms.createOrder` 默认 `RWN-{next_order_id}`，新持久流若重置订单序号会重用 client order ID；OKX `GET /api/v5/trade/order` 对重复 clOrdId 仅返回最新订单。因此单次订单详情查询不能证明旧发送缺席，须把 07-F 的新流身份与缺席证明一起设计，不能由 Demo runner 推断 absent。
- 已实现新流身份的前置条件：Gateway 在显式 dispatch 流初始化时持久保存随机命名空间，恢复时读取同一值；VenueAdapter 可在持久提交前将 OMS 订单身份编码为原生 client ID，实际值随 DispatchProof 保存并供恢复对账使用。OKX 的 32 字符 `clOrdId` 编码留在 OKX Adapter。Debug 与 ReleaseSafe 均 269/269；仍未实现完整的缺席证明，ConfirmedAbsent 保持失败关闭，本票不关闭。

## 2026-09-24 收口证据

- R02-A：`canonical_event.zig` 定义 OrderQueryScope、ReconciliationEvidence 和 AbsenceCoverage；`trading_shard.zig` 只接受与 OMS 订单、规则、时间、会话及覆盖一致的证明，缺项/冲突保持 Unknown、reservation 并锁存 ReconciliationBreak。`oms.zig` 限定 ConfirmedAbsent 为尚无报告/成交的 Unknown place，禁止误释放和迟到成交入账。OKX 私有报告经 `ingestPrivateWs -> tryDrain -> Owner.applyAdapterBatch` 形成 FoundTerminal 并在恢复后保持相同 digest；Binance/Bybit 证据不充分时只发 Unresolved。当前没有 Venue 适配器声称已证明缺席，真实查询覆盖继续由 Venue 资格票验证。
- R02-B：Canonical report 与 reconciliation 均进入同一 `confirmPendingReplacement`；成功及阻断的 CCC 轨迹都经持久 journal 和 replay 验证，旧单终态前不生成重叠 replacement。
- 离线验收：`zig test src/main.zig -ODebug` 271/271；`zig test src/main.zig -O ReleaseSafe` 271/271；`zig fmt --check` 与 `git diff --check` 通过。测试包括缺席证明矩阵、重复/冲突身份、迟到 report/Canonical Fill/Core economic fill、OKX 私有 WS 实际结果与 Owner 恢复。源码工作树身份：HEAD `0d71e8e3cdd66d05303e0dd98e8c2e51f37eb690`，上述 13 个 R02 相关源码文件的 `git diff --binary` SHA-256 为 `8668a2fd7454bb48f1f7cd28a9dc752307f2c4859b14dbf60219fec142fc4b3d`；工作树未提交，包含先前相关改动。
- 持久格式边界：Canonical schema 2、codec 2、journal schema 15、state schema 17；旧持久流按本图规则失败关闭，不自动迁移。离线验收不提升 Demo/Linux/生产资格。

## 2026-09-24 差异摘要复核

- 上述 271/271、journal schema 15、state schema 17 和差异哈希是 02 收口时的历史快照。当前候选提交的源码常量为 journal schema 16、state schema 19；Debug 与 ReleaseSafe 各 269/269。原 02 哈希已失效，且 `git diff --binary` 不包含当时未跟踪的 `src/venue_fill_recovery_acceptance.zig`，不能据此认定 02 有独立补丁。
- 提交前复核新增约束：完整缺席证据中的旧 adapter session 必须匹配目标 OMS place 命令持久保存的 session；结构完整但会话不符的证据保持 Unknown 和占用。现有 Venue 适配器仍不产出正向 ConfirmedAbsent；未来的真实缺席查询必须由各适配器用持久 DispatchProof 的原生 client ID、旧会话及完整历史覆盖验证，生产资格仍待独立验收。
- `src/oms.zig`、`src/trading_shard.zig` 及测试/持久格式文件的 HEAD→工作树差异混合了 02、03 和先前修改；`src/venue_fill_recovery_acceptance.zig` 依赖 `src/raw_ingress.zig`。用户已允许将所需的既有改动和依赖合并提交；本次 `src/main.zig` 只暂存验收导入，Windows 验证链继续留在工作树。
