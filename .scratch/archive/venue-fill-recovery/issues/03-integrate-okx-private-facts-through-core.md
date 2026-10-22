# 贯通 OKX 私有事实到权威状态

Type: task
Status: resolved
Assignee:
Blocked by: [01 分离 Venue 累计成交与已入账 Fill](01-separate-reported-and-applied-fill-quantity.md), [02 闭合 Reconciler 状态转换与容量边界](02-close-reconciler-state-and-capacity.md)
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何证明真实形状的 OKX 私有消息不仅能由 Adapter 产出 report/Fill，还能被 Owner 和 TradingShard
完整接受并形成正确、可恢复的订单与经济状态？

## What to build

使用脱敏固定 OKX 私有消息贯通 public adapter seam、Owner、TradingShard、DurableStore、snapshot
和 replay，并检查 OMS、经济账、费用、余额及最终 digest。fixture 保留 Venue 原始形状，但跨
`VenueAdapter` 后只允许 canonical 领域事实。

## Acceptance criteria

- [x] 至少一条真实脱敏 orders JSON 经 `ingestPrivateWs`、`tryDrain` 和 `applyAdapterBatch` 到达权威状态。
- [x] 全量成交和两次部分成交均验证订单终态、唯一 Fill 总量、PortfolioBalance、PortfolioPosition 和账本闭合。
- [x] maker、taker、BTC 手续费、USDT 手续费和 rebate 均按 canonical 符号与资产归属记账一次。
- [x] 同一 WS 帧重复到达是 no-op；相同身份不同 payload 在核心提交前失败关闭。
- [x] 断线后的 REST 回补与 WS 以相反顺序报告同一成交时，最终状态与 `CanonicalStateDigest` 相同。
- [x] REST order history 只能提供订单/累计事实，不得凭累计数量合成历史 Fill 或费用。
- [x] 原始 Venue 字段不进入 TradingShard、权威日志或 replay；Demo runner 不承担翻译职责。
- [x] live fixture 与 semantic replay 的 digest 相同，replay `writes_sent=0`。
- [x] Debug 与 ReleaseSafe 均通过同一 fixture 矩阵。

## Out of scope

- 连接 OKX 网络或发送 Demo 订单。
- 为测试建立第二套 OKX decoder、Owner 或 TradingShard。

## Gap-to-acceptance plan

Reuse the existing adapter fixture and Owner, but add one public offline test which sends a redacted orders
frame through `ingestPrivateWs`, drains only canonical output, and applies that output through
`Owner.applyAdapterBatch`. Use the same Owner DurableStore recovery path for full and two-partial fills;
assert OMS, applied Fill evidence, economics, fee/rebate assets, account observation, snapshot/replay digest
and replay no-send. Do not inspect `translatePrivate` directly or add a runner-side decoder.

## Progress record

2026-09-22: `src/venue_fill_recovery_acceptance.zig` feeds redacted private subscription/REST bootstrap,
two partial `orders` frames and one full-fill frame through `ingestPrivateWs -> tryDrain ->
Owner.applyAdapterBatch`. It verifies terminal OMS states, unique Fill quantities, closed ledger, BTC maker
fee, USDT taker fee and rebate, duplicate no-op, conflicting identity rejection before any private event
crosses the seam, raw durable replay/recovery and zero transport sends.

The canonical settlement identity is now shared by OKX, Binance and Bybit (`USDT = 1`), rather than mapping
the same asset to a venue-local integer that the core must reject. During a reconciliation barrier, a REST
fill with its bill identity replaces an earlier equivalent buffered WS fill. The reverse arrival test compares
the resulting private event exactly (including raw evidence), so deterministic adapter translation and the
same Owner input state yield the same `CanonicalStateDigest`; it does not relax the separate audit-order
digest rule for ticket 06. REST order history remains report-only in `decodeOrder` and the existing paginated
history regression proves it cannot synthesize a Fill.

Validation: `zig test src/venue_fill_recovery_acceptance.zig` and `-OReleaseSafe` (131/131 each),
`zig test src/okx_private_reconciliation.zig` (21/21), Binance (7/7), Bybit (6/6), `zig fmt --check`, and
`git diff --check` passed. This is offline evidence only; no Demo/Testnet/production write was run.
