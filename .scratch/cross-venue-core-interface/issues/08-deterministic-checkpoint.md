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

- [ ] 状态覆盖冻结计划、阶段/退出原因、经济引用、计时引用、信号、监测、模型窗口/协方差、待成熟标签及下一 IntentSequence。
- [ ] 核心余额、订单、风险与占用仅保存引用或可验证缓存，不成为第二套可写权威。
- [ ] 遵守 PortableStrategyStateJsonV1、StrategyStateDigest 与 StrategyCursor；数值 codec、字段容量、舍入和兼容版本显式定义，禁止 pickle 和任意浮点 JSON。
- [ ] 经 Host 输入与 checkpoint 发布/恢复公共路径比较连续执行、不同批次及不同 checkpoint 切点；规范状态、摘要与意图一致。
- [ ] 边界数值不得因恢复改变方向、数量、目标、阈值判断或身份；非法数值、字段矛盾、损坏内容及容量越界明确拒绝。
- [ ] 验证模型预热、窗口、待成熟标签及随机材料连续性；不能为恢复一致性清空状态或更换 seed。
- [ ] 覆盖 S6-A/B/J/M 及 L/O 的编码部分；按实际支持平台记录数值资格，不以序列化往返代替运行确定性。
- [ ] 记录 schema 确认依据；未冻结字段明确列为验收门槛，核心占用联结交由 09。

## Answer

2026-10-21：已按当前源码核对 Host、PortableState、恢复及候选 checkpoint 路径，形成[实现合同提案](../08-checkpoint-design.md)，列出完整字段、数值 codec、容量、发布/持久恢复和公共测试接缝。当前仍为 accumulator/event_count 示例，不能作为真实模型或 S6 验收证据。

等待用户确认提案的 schema 范围、codec 与容量；确认消息及最终合同版本将作为 schema 冻结依据。尚无功能实现或运行资格证据，所有完成条件保持未勾选。核心占用联结仍归 09，不因本提案提前关闭。
