# 07: 以唯一 Gateway 强制真实 ReduceOnly 与 fencing

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [05 保留强平与未归属经济事实的危险语义](05-preserve-dangerous-account-facts.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何使所有业务订单在唯一 ExecutionGateway 发送边界再次证明不会越权或增加被锁存账户的风险？

## What to build

让 Gateway 只接受完整 OMS DispatchProof，并在真正调用 VenueAdapter 前复核最新带 barrier 的 ExchangePosition、TradingAuthorization、RiskReservation、PrimaryLease、FencingToken、deadline 与 capability。取消原始 OrderCommand 的业务发送入口和 Demo 绕路。

## Acceptance criteria

- [x] place/amend/cancel 的业务外部效果只能通过唯一 Gateway；直接 adapter 调用只保留在 adapter 契约测试和非订单对账 seam。
- [x] latched/RecoveryOnly 状态只放行经当前 ExchangePosition、方向和数量证明真实降低账户净敞口且不穿零的订单；两个 ReduceOnly 布尔值不能单独授权。
- [ ] 每次发送都核对 EffectiveTradingAuthority、有效 RiskReservation、当前 PrimaryLease/FencingToken、CapabilityProfile/规则/配置版本和 DispatchDeadline。
- [x] 旧 token、过期 lease、过期 deadline、stale barrier、缺 reservation、post-only/保护能力缺失均产生 NotSent，不进入 adapter。
- [ ] Gateway 崩溃前后的 Submitted/Unknown、重复 dispatch 和恢复对账保持幂等；replay 类型上不拥有 Gateway。
- [ ] SimulatedVenue 与显式 Demo 路径也通过同一发送边界，且测试证明没有旁路 send。

## Out of scope

- 把 NodeFence 的外部实现或 Venue 网络协议放入 Gateway 核心逻辑。

## Answer

进行中：06 已封闭 OMS 来源事实引用；07 的新公开入口从实际 TradingShard outbox 取命令，复核最新来源引用、账户净仓位、route capability 与 lease，在 adapter 前将 dispatch 身份提交到 DurableStore。提交失败不发送；恢复后的已提交身份仅视为 Unknown，不自动重发。旧 caller-built proof 公开入口失败关闭，SimulatedVenue 离线验证通过。

恢复 Unknown 已增加 OMS 权威对账结案记录：仅在同一订单的最新对账为 FoundLive、FoundTerminal 或 ConfirmedAbsent 且状态一致时持久提交；重启后恢复结案身份，旧 dispatch 永不重发。容量仍有界，耗尽时失败关闭，不声称无限期运行或 Linux 磁盘资格。

尚未满足全部验收：显式 Demo 验收程序的 `fixedStrategyBuy` 使用 `TradingShardHostIngress.initHealthySpotFixtureFor` 生成模拟 OMS 事实，真实私有账户事实只进入独立 `DemoProjection`，而 `dispatch` 仍调用已失败关闭的旧 proof 入口。不能把 fixture shard 伪装成实时权威来源。要使 Demo 真正可发送，必须先有真实 TradingShard 决策日志、私有事实接入、有效 PrimaryLease 与 DurableStore 恢复元数据；本图排除了相关外部 NodeFence、Linux role 和存储实现，故不以伪造事实或线上写入填补。当前证据仅为 Windows 离线测试。
