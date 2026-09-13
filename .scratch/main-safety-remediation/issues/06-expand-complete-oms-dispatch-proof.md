# 06: 扩展完整的 OMS DispatchProof

Type: task
Status: closed
Assignee: Codex
Blocked by: [01 使极值算术与缺失输入失败关闭](01-fail-closed-arithmetic-and-inputs.md), [04 按权威剩余数量维护 RiskReservation](04-rebalance-reservation-from-authoritative-remaining.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让 OMS 输出的每个发送候选携带完整且不可变的交易语义与授权证据，使 Gateway 无需从默认值或调用方上下文猜测？

## What to build

扩展 OMS 的权威命令形态，使 place、amend、cancel 都携带最终 OrderSpec、OrderIntent/RiskDecision/RiskReservation 身份、TradingAuthorization、PrimaryLease/FencingToken、CapabilityProfile、配置版本和 DispatchDeadline。旧形态暂时并存，以便后续调用方分批迁移。

各事实仍由其原所有者演进；OMS 只记录已生效身份、版本和 barrier 的不可变引用，不能把重放的过期 lease 当作新的发送许可。07 的 Gateway 在发送当刻复核最新值。

## Acceptance criteria

- [x] 最终 OrderSpec 完整包含 side、quantity、Market/Limit/PostOnly/IOC/FOK、TIF、价格保护、两种 ReduceOnly 和规范化/降级结果。
- [x] 命令引用产生它的 OrderIntent、RiskDecision、RiskReservation、Order/revision 和 predecessor，不允许调用方重建或补默认值。
- [x] TradingAuthorization、PrimaryLease、FencingToken、CapabilityProfile、InstrumentRules、配置版本和 DispatchDeadline 都绑定明确 barrier。
- [x] 编码、日志、快照和摘要覆盖新增字段；未知版本失败关闭，replay 只重建事实而不获得发送能力。
- [x] expand 阶段保持旧调用方可编译，但任何旧形态不得取得新的生产发送资格。

## Out of scope

- 合并 Venue 私有 wire command、Canonical OrderCommand 与 OMS 内部命令为一个通用类型。

## Answer

OMS Command 保存按 ExchangeAccount/VirtualPortfolio 作用域解释的 OrderIntent、Order/revision/predecessor、真实 RiskDecision/RiskReservation 序号，以及各所有者事实的身份、版本、barrier。新增独立的 CapabilityProfileActivation 事实，绑定 Venue、产品、环境、账户、InstrumentRules、配置及 AdapterSession；DispatchDeadline 由带单调时间的输入和该 profile 的最大派发年龄确定。缺失事实或时间留下不完整引用，不能被视为完整 proof。系统取消在取消事件提交前重新绑定当前控制事实和 deadline，不沿用原 place 的过期 deadline；原命令引用保持不可变。schema 11 的稳定编码、快照校验和状态摘要覆盖这些事实；定向 replay/快照及 Debug/ReleaseSafe 228/228 通过。Gateway 当前仍有调用方构造的上下文，发送时与 DurableStore 的强制复核属于 07，离线完成不代表线上资格。
