# 07: 以唯一 Gateway 强制真实 ReduceOnly 与 fencing

Type: task
Status: closed
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
- [x] 每次发送都核对 EffectiveTradingAuthority、有效 RiskReservation、当前 PrimaryLease/FencingToken、CapabilityProfile/规则/配置版本和 DispatchDeadline。
- [x] 旧 token、过期 lease、过期 deadline、stale barrier、缺 reservation、post-only/保护能力缺失均产生 NotSent，不进入 adapter。
- [x] Gateway 崩溃前后的 Submitted/Unknown、重复 dispatch 和恢复对账保持幂等；replay 类型上不拥有 Gateway。
- [x] SimulatedVenue 与显式 Demo 路径也通过同一发送边界，且测试证明没有旁路 send。
- [x] Demo 私有 Canonical 账户/订单/成交事实进入同一个 TradingShard 权威决策日志，并在持久提交后才可供 Gateway 读取；缺失、拒绝、容量耗尽或恢复不确定时失败关闭，不以 `DemoProjection` 或健康 fixture 冒充权威状态。
- [x] Demo 决策流与 Gateway dispatch 流使用明确的流身份初始化及恢复；启动时不能从“文件不存在”推断新身份，旧已提交 dispatch 恢复为 Unknown，结案后也不能重发。
- [x] Demo 的 PrimaryLease/FencingToken 来自有效、持久且可复核的租约权威；过期、失联、代次不匹配或未配置租约时任何订单都 NotSent。买入、正常清仓和紧急清理使用同一个 `sendFromShard` 边界。
- [x] 以离线注入事实、重启/故障和 spy adapter 验证上述 Demo 链路；不执行 Demo/Testnet/生产写入，亦不把离线通过记为线上资格。
- [x] 显式 Demo 可发送路径以现有 Linux 持久存储/租约适配器实现；现有 Windows 验收程序不是通过条件，也不得将其 fixture 结果计入本票证据。

## Out of scope

- DurableStore 文件适配器自身实现、通用 Linux role、外部 NodeFence、Venue 网络协议、Web 控制面及在线资格；本票只复用既有 seam 和可用的持久租约权威。

## Answer

已完成：唯一 Gateway 从实际 TradingShard outbox 读取命令并在发送当刻重读授权、风险 reservation/lease、规则、配置、capability、账户净仓、持久 PrimaryLease/FencingToken 与 deadline；dispatch 在 adapter 前持久提交，恢复为 Unknown 后只按 OMS 权威对账结案且永不重发。

Linux 显式 Demo 路径使用版本化本地运营配置提供规则、策略激活和风险额度 Core 事实；真实余额、订单、成交、市场和租约事实仍来自 Canonical ingress、LinuxFileAdapter 与 LinuxFencingStore。启动必须显式选择 `virgin` 或 `recover` 及两个流身份，不能以文件缺失推断新历史。买入、正常清仓和已发送后故障清理均经 `Owner.send -> Gateway.sendFromShard`；不支持 Venue 原生 reduce-only 的 Spot 路由仍由 Gateway 以当前账户净仓证明真实减仓。

离线 spy 覆盖提交后发送、重启不重发、私有事实恢复、基础资产手续费净仓及 post-send 故障后的 reduce-only 清理；Debug/ReleaseSafe 全套各 232/232。Linux ReleaseSafe 可执行文件已真实链接，WSL 单所有者 fencing 测试 1/1，通过无配置/无凭证失败关闭探针。未加载真实凭证、未执行 Demo/Testnet/生产写入；外部 NodeFence、CredentialStore execution admission、目标 Linux/Venue 在线资格和生产资格仍不属于本票结论。
