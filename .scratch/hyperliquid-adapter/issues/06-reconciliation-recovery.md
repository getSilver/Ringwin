# 06：对账、Unknown 与持久恢复

Type: task
Status: open
Assignee:
Blocked by: [05 订单与私有事实](05-orders-private-facts.md)
Parent: [模块地图](../map.md)

## Question

如何在启动、断线和重启后证明订单及经济事实完整，无法证明时保持未解决状态？

## What to build

复用既有对账、Owner、DurableStore 与恢复屏障；Adapter 查询与输出证据，不直写 OMS/账本或解除锁存。遵循 ADR 0014 的成交归档与 ADR 0021 的安全恢复边界。

## 完成条件

- [ ] 订单、成交、余额、仓位、保证金、费用、资金费及强制执行的完整范围和分页终止明确；REST 与实时 WS 交错有确定缓冲/去重规则。
- [ ] 覆盖部分/取消/Reduce-only 订单、终态后迟到 Fill、重启重载及历史延迟/截断；不得只复用参考项目有限的普通全成交单补回逻辑。
- [ ] Unknown 保留原命令身份、可能成交范围及风险占用；一次未找到、空页、超时或最近记录窗口不足都不能伪造未发生证明。
- [ ] 相同事实幂等、矛盾内容失败；真实费用不能由推算替代，余额差不补造 Fill，历史不可查证保持 pending/安全限制。
- [ ] 通过公开原始输入→Adapter→applyAdapterBatch→TradingShard→DurableStore 验证故障位置，RawIngress 回放与 snapshot 加尾部重放的 CanonicalStateDigest 收敛。
- [ ] 覆盖归档后重复成交、旧 session、恢复中再次断线与缓冲耗尽；重放零发送，恢复不重发、不延长期限、不重新授权。
- [ ] 原因解除、锁存解除与交易恢复按现有核心合同分别处理；记录实际命令和结果，不用 helper 测试代替公开链路证据。

## Answer

尚未开始。
