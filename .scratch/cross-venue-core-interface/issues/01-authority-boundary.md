# 01：确认跨账户共同准入与周期占用的权威边界

Type: task
Status: in-progress
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何在现有账户、DecisionDomain 和 TradingShard 所有权下，共同准入两腿并可靠恢复周期占用？

## What to build

形成 H2/H3 共用的可实现权威设计，明确两账户路由、共同提交、资金与账户品种占用、周期终结和恢复责任。该票为设计前置，不预选新协调器或 Python 锁表。

## 完成条件

- [x] 以当前公共调用路径与测试核对支持范围，区分已有能力、缺口和不能支持的账户/shard 组合。
- [x] 明确 ExchangeAccount、Instrument、VirtualPortfolio 的校验与唯一所有者；给出 A/B 与 A/C 竞争、不同品种共享资金的决策序列。
- [x] 明确准入拒绝、持久提交、部分发送失败、Unknown、恢复、残余承接与占用释放的状态和责任。
- [x] 给出正常路径和崩溃切点的可检查示例，证明 H2/H3 不复制权威余额或占用。
- [ ] 涉及新权威或难逆决策时列出备选、取舍与确认结果，按需形成领域文档；未确认方案不标 accepted。
- [x] 明确后续票需遵守的身份、容量、错误和兼容合同；若设计超出单票可实施规模，提出追加拆分供确认。

## Answer

已完成当前源码核对与可审阅设计，见 [H2/H3 权威边界设计提案](../authority-design.md) 和 [ADR0017（proposed）](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md)。

上述勾选表示设计材料已交付，不代表提案通过架构确认或多账户功能已实现。源码验证和审查结果见 [本票验证记录](../01-verification.md)。

建议单 DecisionDomain / TradingShard 拥有有界多账户分区并共同提交；跨 shard 组首版拒绝。设计包含唯一所有者、AB/AC 竞争、跨品种资金、分项发送失败、Unknown、残余闭合、崩溃恢复、身份/容量/兼容合同及 05/09 的追加拆分建议。

任务拆分批准不等于架构方案批准。本票等待用户确认架构方案与追加拆分，保持 in-progress；05/09 的依赖不解除，未把提案写成 accepted 或已实现能力。部署与交易仍不在范围内。
