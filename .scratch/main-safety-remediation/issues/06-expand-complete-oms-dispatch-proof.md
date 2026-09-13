# 06: 扩展完整的 OMS DispatchProof

Type: task
Status: in-progress
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
- [ ] 命令引用产生它的 OrderIntent、RiskDecision、RiskReservation、Order/revision 和 predecessor，不允许调用方重建或补默认值。
- [ ] TradingAuthorization、PrimaryLease、FencingToken、CapabilityProfile、InstrumentRules、配置版本和 DispatchDeadline 都绑定明确 barrier。
- [ ] 编码、日志、快照和摘要覆盖新增字段；未知版本失败关闭，replay 只重建事实而不获得发送能力。
- [x] expand 阶段保持旧调用方可编译，但任何旧形态不得取得新的生产发送资格。

## Out of scope

- 合并 Venue 私有 wire command、Canonical OrderCommand 与 OMS 内部命令为一个通用类型。

## Answer

进行中：OMS Command 保留同一 IntentGroup 各成员实际的 IntentSequence；RiskDecision/RiskReservation 已改为两条实际分片事实的不同序号，未准入的旧 OMS 命令持有零引用。place、amend、cancel、重评估 replacement 的新命令引用对应风险事实，系统取消继承原订单来源；快照恢复校验引用，命令历史纳入 schema 10 状态摘要，Debug/ReleaseSafe 227/227。仍缺 TradingAuthorization、PrimaryLease、CapabilityProfile、规则/配置和 deadline 的 OMS 原生版本/barrier 绑定；Gateway proof 仍由调用方构造，不能关闭本票或解锁 07。
