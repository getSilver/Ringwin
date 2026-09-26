# 07: 以唯一 Gateway 强制真实 ReduceOnly 与 fencing

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 保留强平与未归属经济事实的危险语义](05-preserve-dangerous-account-facts.md), [06 扩展完整的 OMS DispatchProof](06-expand-complete-oms-dispatch-proof.md), [08 以 HostActivated 和只读 IPC 强制策略隔离](08-enforce-host-activation-and-ipc-isolation.md), [09 把 legacy 订单与策略调用方迁入权威 OMS](09-migrate-legacy-order-and-strategy-paths.md), [11 实现可重放的订单容量与终态墓碑](11-manage-order-capacity-with-tombstones.md)
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

## 2026-09-23 复核与重开

旧 Answer 和 232/232 仅为历史记录。本轮 [修复计划 R07-A–F](../review-repair-plan-2026-09-23.md#07唯一-gateway-与-linux-demo-恢复)要求逐项验证：

- [x] 对每个 Unknown dispatch 取得新鲜订单级权威对账；缺失时不结案、不重发。起点 `0d71e8e` 的账户对账不能代替订单对账。
- [x] Demo 不自报旧会话失效或可见性等待；未满足 02 的源端证据时保持 Unknown 和 reservation。
- [x] 合法重复 Canonical report/fill 为 no-op，不永久关闭 Owner；冲突、容量或持久故障仍失败关闭。
- [x] 旧 `owner.lock`/lease 接管有外部可核验隔离或 fencing 协议；不得仅凭时钟过期自动接管。离线注入不等于真实 NodeFence 资格。
- [x] BTC/USDT 债务、保证金及额外敞口非零时显式 Demo 路径拒绝发送；用实际私有账户字段构造正反例。
- [x] 旧/未知 schema 及流身份不匹配拒绝恢复发送；只显式初始化新流，不自动清理旧数据或重发已提交 dispatch。

## 2026-09-27 修复证据

- R07-A：`ExecutionGateway.sendFromShard` 把发送前订单 reconciliation ID 写入持久 DispatchProof；恢复结案要求同一订单更大的 ID，旧账户或订单证据不能解开 Unknown。Demo recover 对每个持久 Unknown 从命令历史发起订单查询，缺项停止，永不自动重发。
- R07-B：当前 adapter 和 Demo 路径均不生成调用方自报的会话失效/等待证明位；源端无法确认缺席时维持 unresolved。沿用 02 的 Canonical 对账回归。
- R07-C：`TradingShard.applyStable` 对已验证重复 Canonical 输入返回 no-op；`Owner.apply` 零增量时仅放行此 no-op。重复 report/fill 不增加 barrier，冲突与持久故障仍关闭 Owner。
- R07-D：操作员先取得外部 NodeFence 隔离与读回，再调用 `LinuxFencingStore.recoverFencedOwner`；进程自动释放的独占文件锁串行化 open/close/recover，旧 token 持久撤销后才删除旧 marker，新 owner 取得递增 token。恢复中再次崩溃可在重新核验外部隔离后重试。WSL 注入测试覆盖锁争用、旧/新 owner 和迟到 close；真实目标 NodeFence 资格另由 production-readiness 跟踪。
- R07-E：Demo 初始化和每次发送都检查完整 Canonical 账户投影、BTC/USDT 及其他出现资产的债务、持仓、占用保证金和额外敞口。OKX 完整余额快照只列非零资产，缺席 BTC 按零处理；任何出现资产的债务字段缺失则拒绝。私有字段到 Canonical 的映射与危险/安全样本都有离线回归。
- R07-F：dispatch V3 快照包含 journal schema 与 namespace；决策/dispatch 恢复必须匹配显式 stream 和当前 schema。旧格式、错误身份拒绝恢复；固定轨迹摘要随 schema 13/22/25 重新计算。
- 离线验证：`zig test src/main.zig -O Debug --stack 67108864` 297/297；`zig test src/main.zig -O ReleaseSafe --stack 67108864` 297/297；Linux WSL `zig test src/failover.zig -target x86_64-linux-gnu ...` 10/10；`zig fmt --check` 与 `git diff --check` 通过。未执行任何 Venue 写入，以上不构成线上或生产资格。
