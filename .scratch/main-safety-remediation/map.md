# 收口当前 main 安全与权威状态缺口

Status: active

## Destination

修复[当前 main 代码审查](../../docs/ringwin-main-review.md)确认的安全与业务不变量缺口，使
OrderIntent、Order、RiskReservation、账户危险事实、StrategyHost 授权和唯一发送边界各自只有
一个权威演进路径。完成本波只恢复可信的离线安全基线，不宣称 Linux、Venue 或生产资金资格。

## Definition of done

- 极值数量、价格、费率和累计数量只产生稳定错误，不触发 trap 或静默回绕。
- Canonical Venue 对账能够确定性推进 OMS；ConfirmedAbsent、FoundTerminal 和 Unresolved 具有互斥终态语义。
- OrderIntentIdentity 在 OMS 内语义幂等；CancelConfirmCreate、部分成交和 RiskReservation 在所有入口一致。
- liquidation distance、缺失市场/费用事实和未归属强制成交不会被猜成安全值或任意 VirtualPortfolio 归属。
- 唯一 ExecutionGateway 在发送时复核 ExchangePosition、TradingAuthorization、RiskReservation、PrimaryLease、
  FencingToken、DispatchDeadline 和 CapabilityProfile。
- HostActivated 是可重放的分片权威事实；Python 不能获得可改写 input ring 或游标的能力。
- legacy 订单/风险标量、硬编码 timer 策略和竞争经济投影完成 expand-contract 后删除。
- 有界容量耗尽进入明确 RecoveryOnly；终态压缩保留幂等、对账与 predecessor 证据。
- Debug 与 ReleaseSafe 的成功、极值、冲突、恢复及 live/replay 轨迹全部通过，并封存新的固定证据。

## Rules

- 保留 TradingShard、CanonicalEvent、VenueAdapter、MarketFeedAdapter 和 ExecutionGateway seam；Venue 字段、
  网络、凭证与 Linux 文件 IO 不进入交易核心。
- CoreEvent 的控制、运营和内部事实继续存在；不因边界编码不同而强行合并 Canonical/Core/Host IPC 类型。
- 修根因和共享所有者，不为单个调用点添加旁路；不创建通用 REST、插件、acceptance 或工作流框架。
- 默认 ReleaseSafe；checked arithmetic 是领域合同，不能依赖构建模式替代输入验证。
- 每次只认领并完成一张 Frontier issue；保留用户无关工作树修改。
- 本地图不授权 Demo/Testnet/生产写入，也不默认同步 GitHub Issues。
- DurableStore 自身实现、通用 Linux role、Web 控制面、真实 NodeFence 和在线 Venue 资格继续由既有
  [Linux 生产资格收口](../production-readiness/map.md)跟踪，不在本图复制。06/07 可复用现有
  DurableStore seam；07 另含显式 Demo 路径所需的实时 TradingShard 事实接入、持久决策/dispatch
  流初始化与有效 PrimaryLease 来源；该路径可采用现有 Linux 适配器，不要求改造现有 Windows
  验收程序，也不扩展存储实现、外部 NodeFence 或线上资格。

## Route

2026-09-23 复核后的逐项缺口、修复顺序和重新验收条件见[01–11 源码复核修复计划](review-repair-plan-2026-09-23.md)。下列旧编号继续作为本地票据身份；已通过的旧验收不能代替本轮验证。

1. [使极值算术与缺失输入失败关闭](issues/01-fail-closed-arithmetic-and-inputs.md)
2. [让 Canonical Venue 对账推进 OMS](issues/02-apply-canonical-reconciliation-to-oms.md)
3. [闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](issues/03-enforce-oms-intent-idempotency.md)
4. [按权威剩余数量维护 RiskReservation](issues/04-rebalance-reservation-from-authoritative-remaining.md)
5. [保留强平与未归属经济事实的危险语义](issues/05-preserve-dangerous-account-facts.md)
6. [扩展完整的 OMS DispatchProof](issues/06-expand-complete-oms-dispatch-proof.md)
7. [以唯一 Gateway 强制真实 ReduceOnly 与 fencing](issues/07-enforce-authoritative-gateway-send.md)
8. [以 HostActivated 和只读 IPC 强制策略隔离](issues/08-enforce-host-activation-and-ipc-isolation.md)
9. [把 legacy 订单与策略调用方迁入权威 OMS](issues/09-migrate-legacy-order-and-strategy-paths.md)
10. [删除竞争订单状态与废弃经济投影](issues/10-contract-legacy-state-and-projection.md)
11. [实现可重放的订单容量与终态墓碑](issues/11-manage-order-capacity-with-tombstones.md)
12. [重建 main 安全与权威状态验收基线](issues/12-rebuild-safety-acceptance.md) — blocked by 01–11

## Frontier

- 下一张可认领：[12 重建 main 安全与权威状态验收基线](issues/12-rebuild-safety-acceptance.md)。01–11 已逐票离线收口，12 最后重建验收。Linux/Venue/生产资金资格仍为 not_run。

## Decisions so far

- 2026-09-27：07 按 R07-A–F 收口。Unknown 必须取得发送后新鲜订单级对账；重复 Canonical 输入保留 Owner；Demo 对债务/保证金/额外敞口失败关闭；旧 owner 经外部隔离读回、持久撤销和内核锁串行接管；dispatch V3 拒绝旧 schema。Debug/ReleaseSafe 各 297/297，Linux WSL fencing 10/10，均属离线证据。12 待重新封存全波，不升级线上资格。
- 2026-09-26：11 按 R11-A 收口。OMS 热单保存每单自身意图序号，墓碑不再把多成员或 CCC successor 的意图身份误写为组首；归档摘要覆盖该身份与关键来源。压缩后的重复/冲突意图、迟到报告、predecessor 和摘要篡改回归通过；现有容量、Gateway gate、registry 与 snapshot/tail 恢复测试继续通过。Debug（Windows 64 MiB 栈）/ReleaseSafe 各 295/295，acceptance/journal/state/registry schema 12/21/24/18；仅离线证据，完整封存留 12 票。
- 2026-09-26：10 在 09 完成后按修复计划重新验收，未发现旧订单/风险/经济权威或业务 raw send 回流；保留的模拟生命周期投影只用于当前 Demo 验收摘要，不参与交易准入或发送。核心与 Demo 文件格式检查通过，当前工作树 Debug（Windows 64 MiB 栈）/ReleaseSafe 各 294/294；完整源码身份待 12 票封存，Linux/Venue/生产资金资格保持 `not_run`。
- 2026-09-26：09 按 R09-A 收口。真实 Host、timer 与 OMS group 入口把未激活、身份冲突、open Order、能力、市场及风险拒绝写为有原因的稳定事实；拒绝占用 OMS 意图身份，Python 请求身份元数据进入原始指纹。首记录拒绝原因经 journal/replay 校验，身份容量耗尽有持久 RecoveryOnly 事实。Debug（Windows 64 MiB 栈）/ReleaseSafe 各 294/294，journal/state/acceptance/registry schema 20/23/11/17；仅离线证据。
- 2026-09-25：06 按 R06-A/B 收口。TradingAuthorization 引用真实授权变化事实；CancelOpenOrders 不覆盖授权。OMS/分片/Gateway 只接受可原样表达的订单语义，不支持的能力、改单、价格保护和规则版本留下可回放拒绝事实；暂停后旧 proof 无发送。Debug/ReleaseSafe 各 292/292，journal/state/acceptance/registry schema 19/22/10/16；仅离线证据。
- 2026-09-24：08 按 R08-A 收口。HostActivated 绑定非零 session 与可回放激活事实；故障、控制暂停与新会话撤权旧身份，Gateway 从分片 journal 事实开权并守住 barrier、cursor 和批次连续性。Debug/ReleaseSafe 各 288/288，StrategyHost 14 步离线验证通过；journal/state schema 18/21。Linux 目标与 Venue/生产资格保持 `not_run`。
- 2026-09-24：05 按 R05-A/B 收口。强平来源统一进 Suspense，权威多切片守恒数量、PnL、费用、罚金与仓位；源与已完成分配可重放，分片提交/确认崩溃窗口须刷新摘要且拒绝夹带漂移。Debug/ReleaseSafe 各 283/283，协调器 snapshot/tail schema 5/2，分片 journal/state schema 17/20；仅离线证据，目标 DurableStore 同步与 Linux/Venue 资格待验。
- 2026-09-24：04 按 R04-A 收口 PendingAmend 的旧/新剩余占用、Unknown 阻断、拒绝回退和迟到对账。OMS/TradingShard 公共入口与事件重放回归通过；Debug 需 Windows 64 MiB 测试栈，ReleaseSafe 使用默认栈，均 275/275。仅离线证据。
- 2026-09-24：提交前复核将 02 的 ConfirmedAbsent 绑定到原 place 命令的 adapter session，将 03 的意图内容摘要扩至 128 位；候选提交的 Debug/ReleaseSafe 各 269/269，journal/state schema 16/19。现有 Venue 仍不产生正向缺席证明，真实查询与资金资格保持待验。
- 2026-09-24：03 按 R03-A/B/C 收口。OMS 按原始 group 身份在风控前去重；同身份冲突写入可重放 trace；部分成交或 FoundLive 不清除待决取消阻断，CCC 重查全局阻断、目标屏障与授权。Debug/ReleaseSafe 273/273，journal/state schema 16/18；仅为离线证据。
- 2026-09-24：02 按 R02-A/R02-B 收口。通用证据范围与缺席覆盖在 Canonical，OKX 原始私有事实的翻译留在 OKX Adapter；证据不足的 Venue 输出 Unresolved。Canonical report/reconciliation 共用 OMS/CCC 转换，OKX 私有 WS 到 Owner 持久恢复及缺席证据失败关闭轨迹通过 Debug/ReleaseSafe 271/271。真实 Venue 缺席查询覆盖仍属生产资格票，不从离线结果推定。
- 2026-09-23：01–11 源码复核发现 02–09、11 尚有未满足的验收条件，12 的封存陈述与当前源码不符；撤回整图已关闭结论，按[修复计划](review-repair-plan-2026-09-23.md)重开并逐票验证。01、10 无本轮确认的新缺陷；10 待 09 后重新回归。
- 2026-09-23：VenueAdapter 负责私有查询证据到通用 Canonical 对账的验证；Host 故障/重启撤销旧激活；Demo 对非零债务、保证金和额外敞口失败关闭；旧 owner 接管需外部可核验 fencing；订单只接受 exact-only；开发阶段不兼容旧持久流，旧 schema 不自动恢复发送，也不自动删除旧数据。本计划不授权 Venue 写入。
- 2026-09-17：12 以 `tools/verify-core-wave.ps1` 重封存离线验收。Debug/ReleaseSafe 239/239；journal/state schema 14/15；CCC、墓碑归档、持久 dispatch 与 replay 无发送均有机器可读 live/replay 证据。不升级 Linux/Venue/生产资格。
- 2026-09-17：11 以 FoundTerminal/ConfirmedAbsent 作为迟到事实窗口关闭，并在热 Order 上提交 archive audit digest。compact 不得淘汰 Unknown、PendingCancel、未闭合 reservation、CCC replacement 或仍被热表 predecessor 引用的订单；无窗口终态单在容量压力下保持热表并 RecoveryOnly。本波最低安全边界不定义生产保留天数。
- 2026-09-17：09 删除 Canonical report/fill 的 shard 镜像标量。报告身份进入 OMS，成交身份进入经济投影；风险查询与协调摘要从 OMS reservation owner 派生，不再保存 `layered_risk_reserved_micros`。
- 2026-09-14：用户允许 07 使用显式、版本化的 Demo 专属本地运营配置提供规则、策略激活与风险额度 Core 事实；实际账户状态仍由私有 Canonical 事实提供，配置不得直接生成可发送 proof。
- 2026-09-14：用户确认显式 Demo 可发送路径不必支持现有 Windows 程序；07 以可复用现有持久存储和租约适配器的 Linux 路径收口，Windows 旧验收程序不作为 07 通过证据。
- 2026-09-14：用户同意在本图 07 实现恢复 Unknown 结案和显式 Demo 真实来源链，并将 Demo 专属实时 TradingShard、持久决策日志初始化及有效租约来源纳入；仍不授权任何 Demo/Testnet/生产写入，也不把 Linux/外部 NodeFence/在线资格视为已通过。
- 2026-09-13：06 不新增包揽 lease/capability/risk 的通用授权事实；OMS 命令记录各权威事实的真实身份、版本和 barrier，缺失事实优先扩展原事实来源。Gateway 在 07 发送当刻重读最新授权；重放旧 lease 只供审计/对账，不恢复发送权。
- 2026-09-12：用户允许把复用现有 DurableStore seam 的预发送持久提交纳入 06/07；不另建存储系统，不迁入 Linux role、外部 NodeFence、Venue 协议或在线/生产资格。
- 2026-09-12：最终 Spec 复核撤销“本波已完成”结论。06/07/09/11/12 保持待收口；离线测试通过不证明 OMS 原生 proof、持久 pre-send 事实或墓碑归档资格。
- 2026-09-11：最终两轴审查补齐 Gateway 自有权威事实与 dispatch 幂等、墓碑精确审计证据、Suspense 容量原子拒绝及 hostile-child capability 验收。
- 2026-09-10：曾按 schema 9 标记 01–12 完成；2026-09-12 最终复核撤销该结论。Python StrategyHost 已改为 Zig supervisor 校验的管道复制，
  不再获得任何 shared-memory/fd/mapping/cursor 能力；离线验收不升级 Linux/Venue/生产资金资格。
- 2026-09-09：按当前源码重新核验审查结论；15 项业务逻辑缺口仍存在，安全问题按实际利用边界修订。
- 2026-09-09：用户批准以 12 张 tracer-bullet issue 收口核心安全缺口，并定向补强既有生产资格票。
- H2 按 ReleaseSafe 下的 trap/拒绝服务风险处理，同时禁止未来 ReleaseFast 静默回绕；不沿用“当前必然少占保证金”的过强结论。
- HostActivated 修复覆盖直接 trade 与 recovery 两条路径；Python 不获得 shared-memory capability，权限由 Zig 校验的有界 pipe bridge 强制。
- `production_candidate` 保留为目标范围；required capability 与 verified evidence 在生产资格票中分开。
- 竞争状态使用 expand-contract：先扩展 OMS 权威形态，再迁移调用方，最后删除 legacy 形态。

## Not yet specified

- 终态墓碑的生产保留窗口与容量上限；本波先用确定性压力验收给出最低安全边界。
- 目标 Linux 的独立 fencing authority、文件系统、节点和 Venue 账户；继续由 production-readiness tracker 冻结。

## Out of scope

- 真实资金、生产执行凭证或新的 Venue 写入授权。
- 通用 REST/WS/auth 插件框架、第二套控制面、独立控制面 CLI。
- SOR、期权、组合保证金、跨区域多活和策略盈利能力。
