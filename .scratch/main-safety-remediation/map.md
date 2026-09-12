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
- DurableStore、Linux role、Web 控制面、真实 NodeFence 和在线 Venue 资格继续由既有
  [Linux 生产资格收口](../production-readiness/map.md)跟踪，不在本图复制。

## Route

1. [使极值算术与缺失输入失败关闭](issues/01-fail-closed-arithmetic-and-inputs.md)
2. [让 Canonical Venue 对账推进 OMS](issues/02-apply-canonical-reconciliation-to-oms.md)
3. [闭合 OMS 意图幂等与 CancelConfirmCreate 阻断](issues/03-enforce-oms-intent-idempotency.md) — blocked by 02
4. [按权威剩余数量维护 RiskReservation](issues/04-rebalance-reservation-from-authoritative-remaining.md) — blocked by 02, 03
5. [保留强平与未归属经济事实的危险语义](issues/05-preserve-dangerous-account-facts.md)
6. [扩展完整的 OMS DispatchProof](issues/06-expand-complete-oms-dispatch-proof.md) — blocked by 01, 04
7. [以唯一 Gateway 强制真实 ReduceOnly 与 fencing](issues/07-enforce-authoritative-gateway-send.md) — blocked by 05, 06
8. [以 HostActivated 和只读 IPC 强制策略隔离](issues/08-enforce-host-activation-and-ipc-isolation.md)
9. [把 legacy 订单与策略调用方迁入权威 OMS](issues/09-migrate-legacy-order-and-strategy-paths.md) — blocked by 03, 04, 06, 08
10. [删除竞争订单状态与废弃经济投影](issues/10-contract-legacy-state-and-projection.md) — blocked by 09
11. [实现可重放的订单容量与终态墓碑](issues/11-manage-order-capacity-with-tombstones.md) — blocked by 03, 04, 10
12. [重建 main 安全与权威状态验收基线](issues/12-rebuild-safety-acceptance.md) — blocked by 01–11

## Frontier

- [06 扩展完整的 OMS DispatchProof](issues/06-expand-complete-oms-dispatch-proof.md)；最终 Spec 复核发现 proof 仍由调用方重建。07 的崩溃安全发送还需要决定是否纳入本图原本排除的 DurableStore。

## Decisions so far

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
