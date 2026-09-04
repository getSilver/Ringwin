# 06: 让 Binance 通过统一 Gateway 完成端到端路径

Type: task
Status: resolved
Assignee:
Blocked by: [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让现有 Binance SPOT 与 linear 能力真正通过统一 VenueAdapter 和 Execution Gateway 闭环，而不是
只证明字段解析或可自行声明的准入结构？

## What to build

把 Binance 的规范 Instrument、行情、订单、私有账户事实和 reconciliation 接入统一 seam，并用可控
transport 完成无凭据的端到端合约轨迹。Venue 私有字段只保留在 RawIngress 和 adapter 内，核心只接收
CanonicalEvent。

## Blocked by

- [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)

## Acceptance

- [ ] Binance SPOT 与 linear Instrument 使用 registry 中的规范身份和规则完成 place、cancel、reject、fill 与 reconciliation。
- [ ] 行情 snapshot/delta、账户观察和执行回报均经过统一 CanonicalEvent seam，不向 TradingShard 泄漏 Venue 私有字段。
- [ ] 重复、乱序、未知结果、行情 gap 和账户 gap 均触发与 SimulatedVenue/OKX 相同的幂等或 fail-closed 合同。
- [ ] Binance adapter 故障只收紧其所属 ExchangeAccount/Instrument，不改变 OKX 或 SimulatedVenue 的权威状态。
- [ ] 离线合约轨迹无需生产账户或密钥，且 live/replay 的核心摘要相同、replay 无发送。

## Evidence

- Binance venue and private-reconciliation suites use the common `VenueAdapter` and canonical market/account/output facts.
- `zig test src/main.zig`: 178/178 passed, including duplicate/gap/unknown/reconciliation and Binance adapter tests.
- Default core wave is offline and does not require credentials.
