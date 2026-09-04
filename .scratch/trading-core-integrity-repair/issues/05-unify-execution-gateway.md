# 05: 收敛为唯一 Execution Gateway

Type: task
Status: resolved
Assignee:
Blocked by: [01](01-commit-account-projection-failure.md), [02](02-unify-market-continuity-authority.md), [04](04-close-multi-instrument-trading-loop.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让 Account 唯一所有者、TradingShard 和 VenueAdapter 共享一个真实执行接缝，替代彼此断开的
Gateway 模型和测试合成结果，同时保持恢复路径无发送能力？

## What to build

打通 TradingShard outbox 到按 ExchangeAccountIdentity 唯一路由的 Execution Gateway，再到 SimulatedVenue
和 OKX VenueAdapter，并把 adapter 结果规范化为 CanonicalEvent 返回 TradingShard。Gateway 必须在
正常和受限模式下按 EffectiveTradingAuthority 区分新增风险与撤单、reduce-only、reconciliation，
而 replay 类型不能取得 Gateway 能力。

## Blocked by

- [01: 提交 AccountProjection 的失效事实](01-commit-account-projection-failure.md)
- [02: 统一市场连续性与恢复权威](02-unify-market-continuity-authority.md)
- [04: 在同一 TradingShard 完成 SPOT 与线性合约闭环](04-close-multi-instrument-trading-loop.md)

## Acceptance

- [ ] 一个 OrderIntent 经风险与 OMS 后由唯一 Gateway 发送到 SimulatedVenue，并由返回事实推进同一 Order 生命周期。
- [ ] OKX 使用同一 Gateway/VenueAdapter 契约完成离线 place、cancel、reject 和 reconciliation 轨迹，不再有核心旁路。
- [ ] 同一 ExchangeAccountIdentity 的重复或歧义 route 配置被拒绝，不再采用“第一个匹配”或静默覆盖。
- [ ] OpeningGate 关闭时新增风险命令被拒绝，但授权撤单、PortfolioReduceOnly/VenueReduceOnly 和 reconciliation 可执行。
- [ ] adapter 或 route 容量耗尽时 fail-closed；一个账户失败不会错误发送到其他账户或 Venue。
- [ ] live 轨迹记录确定发送次数；全量 replay、snapshot-tail replay 和恢复构造均证明发送次数为零。

## Evidence

- `src/execution_gateway.zig` now rejects duplicate account routes, scopes unknown/reconciliation failures, bounds instrument gates and exposes one canonical adapter request route.
- Restricted mode permits cancel and reduce-only commands while blocking increasing risk; adapter errors latch only the owning account.
- Offline adapter contract suites cover SimulatedVenue, OKX, Binance and Bybit; four-shard evidence reports `live_gateway_submissions=4` and `replay_send_capability=false`.
