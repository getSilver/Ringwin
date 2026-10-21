# 08：版本化策略状态与确定性 checkpoint

Type: task
Status: in_progress
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何使真实策略私有状态在连续运行、不同输入分批与 checkpoint 重放后保持相同摘要和意图？

## What to build

提供显式有界、版本化的策略状态与数值编码，贯通 Host checkpoint 发布和恢复。可先开展接口核对与设计；最终验收必须绑定确认后的策略 schema。

## 完成条件

- [x] 状态覆盖冻结计划、阶段/退出原因、经济引用、计时引用、信号、监测、模型窗口/协方差、待成熟标签及下一 IntentSequence。
- [x] 核心余额、订单、风险与占用仅保存引用或可验证缓存，不成为第二套可写权威。
- [x] 遵守 PortableStrategyStateJsonV1、StrategyStateDigest 与 StrategyCursor；数值 codec、字段容量、舍入和兼容版本显式定义，禁止 pickle 和任意浮点 JSON。
- [ ] 经 Host 输入与 checkpoint 发布/恢复公共路径比较连续执行、不同批次及不同 checkpoint 切点；规范状态、摘要与意图一致。
- [ ] 边界数值不得因恢复改变方向、数量、目标、阈值判断或身份；非法数值、字段矛盾、损坏内容及容量越界明确拒绝。
- [ ] 验证模型预热、窗口、待成熟标签及随机材料连续性；不能为恢复一致性清空状态或更换 seed。
- [ ] 覆盖 S6-A/B/J/M 及 L/O 的编码部分；按实际支持平台记录数值资格，不以序列化往返代替运行确定性。
- [x] 记录 schema 确认依据；未冻结字段明确列为验收门槛，核心占用联结交由 09。

## Answer

2026-10-21：用户明确答复「批准该提案，继续实现」，确认[实现合同](../08-checkpoint-design.md)的 schema 范围、codec、容量及公共接缝；随后明确收窄为「仅完成 checkpoint 基础设施，模型验收保持待定」。本轮不实现或启用研究模型，不以序列化往返关闭运行确定性验收，整票保持 in_progress。

基础设施已实现版本化有界私有状态、无损 binary64 组成编码、精确整数/有理数目标校验、Host checkpoint 请求/响应、独立预期元数据与会话/请求身份验证，以及 DurableStore 内容先于 catalog 引用的持久发布和关闭重开恢复。schema 区分冻结/未冻结目标，保留 Unknown 引用、期限、模型窗口/协方差、标签和随机材料；非法字段、非有限值、矛盾阶段及超容量拒绝。旧 accumulator/event_count 示例保持独立，不能冒充真实模型资格。

尚缺真实策略输入更新、不同分批/切点运行一致性、预热/标签成熟/随机消费连续性和数值边界决策证据；S6-A/B/J/M 及 L/O 的运行部分仍未通过。核心占用、依赖产物可解析性及最终激活联结归 09；catalog 发布事实尚非 TradingShard 核心周期事实。最终命令、平台和审查见 [08 验证记录](../08-verification.md)。
