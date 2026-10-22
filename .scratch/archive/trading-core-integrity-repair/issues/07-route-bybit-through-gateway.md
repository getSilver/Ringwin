# 07: 让 Bybit 通过统一 Gateway 完成端到端路径

Type: task
Status: resolved
Assignee:
Blocked by: [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让现有 Bybit SPOT 与 linear 能力通过和 OKX、Binance 相同的契约完成真实核心闭环，并保持 Venue
故障隔离？

## What to build

把 Bybit 的规范 Instrument、行情、订单、私有账户事实和 reconciliation 接入统一 seam，并以可控
transport 覆盖完整离线执行轨迹。任何 Bybit 特有枚举、身份或错误码必须在 adapter 边界内翻译。

## Blocked by

- [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)

## Acceptance

- [x] Bybit SPOT 与 linear Instrument 使用 registry 中的规范身份和规则完成 place、cancel、reject、fill 与 reconciliation。
- [x] 行情与账户事实只以 CanonicalEvent 进入核心，原始枚举、错误码和 transport 结构保留为边界证据。
- [x] 重复、乱序、未知结果、行情 gap 和账户 gap 满足统一幂等及 fail-closed 合同。
- [x] Bybit adapter 故障只收紧其所属 ExchangeAccount/Instrument，不改变 Binance、OKX 或 SimulatedVenue 状态。
- [x] 离线合约轨迹无需生产账户或密钥，且 live/replay 的核心摘要相同、replay 无发送。

## Evidence

- Bybit execution now enters its existing `VenueAdapter` through `execution_gateway.Gateway`; account/capability/config/session checks precede transport.
- Bybit venue and private-reconciliation suites use canonical market/account/output facts and cover duplicate/gap/unknown/reconciliation behavior.
- `zig test src/main.zig -O Debug` and `-O ReleaseSafe`: 182/182 passed.
- Default core wave is offline and does not require credentials.
