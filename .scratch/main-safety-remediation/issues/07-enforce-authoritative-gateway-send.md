# 07: 以唯一 Gateway 强制真实 ReduceOnly 与 fencing

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [05 保留强平与未归属经济事实的危险语义](05-preserve-dangerous-account-facts.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何使所有业务订单在唯一 ExecutionGateway 发送边界再次证明不会越权或增加被锁存账户的风险？

## What to build

让 Gateway 只接受完整 OMS DispatchProof，并在真正调用 VenueAdapter 前复核最新带 barrier 的 ExchangePosition、TradingAuthorization、RiskReservation、PrimaryLease、FencingToken、deadline 与 capability。取消原始 OrderCommand 的业务发送入口和 Demo 绕路。显式 Demo 路径也必须由实时 TradingShard 产生命令，复用 DurableStore seam 初始化和恢复决策/dispatch 流，并从有效的持久租约权威取得 PrimaryLease；不能用 fixture、调用方构造的 proof 或进程内自增 token 代替。

## Acceptance criteria

- [x] place/amend/cancel 的业务外部效果只能通过唯一 Gateway；直接 adapter 调用只保留在 adapter 契约测试和非订单对账 seam。
- [x] latched/RecoveryOnly 状态只放行经当前 ExchangePosition、方向和数量证明真实降低账户净敞口且不穿零的订单；两个 ReduceOnly 布尔值不能单独授权。
- [ ] 每次发送都核对 EffectiveTradingAuthority、有效 RiskReservation、当前 PrimaryLease/FencingToken、CapabilityProfile/规则/配置版本和 DispatchDeadline。
- [x] 旧 token、过期 lease、过期 deadline、stale barrier、缺 reservation、post-only/保护能力缺失均产生 NotSent，不进入 adapter。
- [ ] Gateway 崩溃前后的 Submitted/Unknown、重复 dispatch 和恢复对账保持幂等；replay 类型上不拥有 Gateway。
- [ ] SimulatedVenue 与显式 Demo 路径也通过同一发送边界，且测试证明没有旁路 send。
- [ ] Demo 私有 Canonical 账户/订单/成交事实进入同一个 TradingShard 权威决策日志，并在持久提交后才可供 Gateway 读取；缺失、拒绝、容量耗尽或恢复不确定时失败关闭，不以 `DemoProjection` 或健康 fixture 冒充权威状态。
- [ ] Demo 决策流与 Gateway dispatch 流使用明确的流身份初始化及恢复；启动时不能从“文件不存在”推断新身份，旧已提交 dispatch 恢复为 Unknown，结案后也不能重发。
- [ ] Demo 的 PrimaryLease/FencingToken 来自有效、持久且可复核的租约权威；过期、失联、代次不匹配或未配置租约时任何订单都 NotSent。买入、正常清仓和紧急清理使用同一个 `sendFromShard` 边界。
- [ ] 以离线注入事实、重启/故障和 spy adapter 验证上述 Demo 链路；不执行 Demo/Testnet/生产写入，亦不把离线通过记为线上资格。
- [ ] 显式 Demo 可发送路径以现有 Linux 持久存储/租约适配器实现；现有 Windows 验收程序不是通过条件，也不得将其 fixture 结果计入本票证据。

## Out of scope

- DurableStore 文件适配器自身实现、通用 Linux role、外部 NodeFence、Venue 网络协议、Web 控制面及在线资格；本票只复用既有 seam 和可用的持久租约权威。

## Answer

进行中：06 已封闭 OMS 来源事实引用；07 的新公开入口从实际 TradingShard outbox 取命令，复核最新来源引用、账户净仓位、route capability 与 lease，在 adapter 前将 dispatch 身份提交到 DurableStore。提交失败不发送；恢复后的已提交身份仅视为 Unknown，不自动重发。旧 caller-built proof 公开入口失败关闭，SimulatedVenue 离线验证通过。

恢复 Unknown 已增加 OMS 权威对账结案记录：仅在同一订单的最新对账为 FoundLive、FoundTerminal 或 ConfirmedAbsent 且状态一致时持久提交；重启后恢复结案身份，旧 dispatch 永不重发。容量仍有界，耗尽时失败关闭，不声称无限期运行或 Linux 磁盘资格。

尚未满足全部验收：显式 Demo 验收程序的 `fixedStrategyBuy` 使用 `TradingShardHostIngress.initHealthySpotFixtureFor` 生成模拟 OMS 事实，真实私有账户事实只进入独立 `DemoProjection`，而 `dispatch` 仍调用已失败关闭的旧 proof 入口。不能把 fixture shard 伪装成实时权威来源。2026-09-14 用户已把 Demo 专属的实时 TradingShard 事实接入、持久决策/dispatch 流初始化和有效 PrimaryLease 来源纳入本票；实现与离线故障验收仍待完成，外部 NodeFence、通用 Linux role、存储适配器自身及线上资格仍排除。当前证据仅为 Windows 离线测试。

同日平台选择：不要求修通现有 Windows Demo 程序；Linux 显式 Demo 路径可复用既有 `LinuxFileAdapter` 与 `LinuxFencingStore`。这只确定实现平台，不表示目标 Linux 文件系统、租约外部协调或 Venue 在线资格已通过。
