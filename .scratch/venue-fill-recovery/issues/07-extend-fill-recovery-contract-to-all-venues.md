# 把成交恢复合同推广到所有 VenueAdapter

Type: task
Status: resolved
Assignee:
Blocked by: [05 用假 transport 闭合 Demo runner 生命周期](05-close-demo-runner-lifecycle-offline.md), [06 固定 report、Fill 与 reconciliation 的顺序不变量](06-prove-private-fact-order-invariants.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何证明本轮修复属于共享 TradingShard 与 VenueAdapter 合同，而不是只让 OKX fixture 通过的特判？

## What to build

扩展现有共享 VenueAdapter 合同，并让 SimulatedVenue、Binance 和 Bybit 以各自最小 fixture 通过同一
成交、身份、恢复和 replay 不变量。只有 Venue 私有解析留在实现内；合同断言全部使用 canonical
领域事实。

## Acceptance criteria

- [x] 三个 Adapter 均使用与 OKX 相同的 canonical identity、重复 no-op 和冲突失败关闭合同。
- [x] report/Fill 顺序独立性、部分成交累计和 overfill 边界在每个 Adapter 上至少有一条端到端用例。
- [x] Unknown 只能经权威 reconciliation 恢复，不能由 Adapter 或 runner 自动重发。
- [x] fee 与 rebate 的资产、符号和 maker/taker 语义在跨 seam 后规范一致。
- [x] ExchangeAccount 范围在每个 fixture 中明确，跨账户身份或事实失败关闭。
- [x] live 与 replay 最终 digest 相同，replay 对所有 Adapter 均无发送能力。
- [x] 复用现有合同入口和最小 fixture，不创建新 interface、工厂、插件系统或 Venue 专用核心分支。
- [x] Debug 与 ReleaseSafe 均运行同一共享合同矩阵。

## Out of scope

- 新 Venue、真实 Testnet/Demo 网络资格或扩展支持产品范围。
- 把各 Venue 的私有字段提升为核心领域字段。

## Gap-to-acceptance plan

After 05 and 06, parameterize the existing shared contract harness with the canonical facts emitted by each
adapter's smallest fixture. It must cover duplicate/conflicting identity, partial/full Fill accounting,
overfill, reconciliation of Unknown, exchange-account scope and replay no-send without inspecting private
protocol fields.

## Evidence

2026-09-23: extended `venue_adapter_contract.exerciseFillRecovery` over the existing public
`VenueAdapter.tryDrain` batch. It checks canonical event type, Venue/ExchangeAccount/session scope, report
quantities, unique applied Fill totals at the original-quantity boundary, and non-negative normalized
fee/rebate values. `SimulatedVenue` now emits its deterministic place as accepted, Fill, partial report, Fill,
filled; an Unknown blocks a new non-cancel command until an explicit order reconciliation is drained. Binance
and Bybit each feed two actual private partial Fill frames through their adapter and this shared contract; their
duplicate raw Fill produces no second batch, and an off-account reconciliation request fails closed. Existing
core 06 permutations cover report/Fill ordering, duplicate/conflict and `TradingShard` replay no-send; the
Binance and new Bybit private-reconciler replay rows reproduce identical canonical records, while SimulatedVenue
has no transport capability. Debug passed Simulated 10/10, Binance 32/32 and Bybit 31/31; the same three
ReleaseSafe runs passed. No network action or root-suite run occurred.
