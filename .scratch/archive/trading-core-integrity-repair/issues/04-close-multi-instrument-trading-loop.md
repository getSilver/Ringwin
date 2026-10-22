# 04: 在同一 TradingShard 完成 SPOT 与线性合约闭环

Type: task
Status: resolved
Assignee:
Blocked by: [03: 将单一 Instrument 配置扩展为有界注册表](03-expand-bounded-instrument-registry.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何证明同一 TradingShard 能同时处理规范 SPOT 与 isolated linear USDT 永续，而不是仅在容器中保存
多个订单却仍共享一份 Instrument 配置？

## What to build

完成一个双 Instrument 纵向场景：两个 OrderIntent 分别经过规范化、分层风险、OMS、OrderCommand、
ExecutionReport、Fill、PortfolioPosition、PortfolioBalance、保证金、PnL 和 LedgerTransaction。任一
Instrument 的规则、报告或失败不能改变另一个 Instrument 的状态。

## Blocked by

- [03: 将单一 Instrument 配置扩展为有界注册表](03-expand-bounded-instrument-registry.md)

## Acceptance

- [x] 同一 TradingShard 在一个确定轨迹中接受规范 SPOT 与 linear Instrument 的 OrderIntent，并产生各自正确的 OrderCommand。
- [x] SPOT 现金约束与 linear 逐仓保证金约束分别使用对应注册规则，不能跨 Instrument 读取或释放 reservation。
- [x] 两个 Instrument 的部分成交、终态、费用、Realized/UnrealizedPnL 和账本分录均按所有权独立闭合。
- [x] 向一个 Instrument 发送另一 Instrument 的 ExecutionReport、Fill 或规则版本时原子拒绝，另一侧状态不变。
- [x] live、全量 replay 和 snapshot-tail replay 的双 Instrument CanonicalStateDigest 相同。

## Evidence

- OMS orders, reports, fills and risk qualification now resolve instrument ownership and rules per registry/OMS order rather than the scalar active instrument.
- Spot and linear economics carry explicit registry-derived product semantics, independent marks and quantity denominators into separate product positions.
- `SPOT and linear instruments close economics and replay independently` covers commands, partial/final reports, fills, reservations, PnL, cross-Instrument rejection, full replay and snapshot-tail replay.
- `zig test src/main.zig -O Debug` and `-O ReleaseSafe`: 180/180 passed.
