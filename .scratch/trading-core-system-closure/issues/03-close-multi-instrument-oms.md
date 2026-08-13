# 闭合多 Instrument SPOT 与永续 OMS 生命周期

Type: task
Status: resolved
Assignee: Codex
Blocked by: 02
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何让同一 TradingShard 同时维护有界的多 Instrument、多 Order 生命周期，闭合 SPOT 与 isolated/net USDT 永续的 place/amend/cancel、IntentGroup、逐项 batch、CancelConfirmCreate、Unknown 和终态幂等，而不把 Venue 字段或 Adapter 调度带入核心？

## Answer

在 `TradingShard` 内加入固定容量的领域 OMS：同一实例最多维护 8 个 SPOT/SWAP 订单，单个 `IntentGroup` 最多 4 项、单次命令输出最多 8 项；输入和输出只使用规范化 Instrument、订单身份、revision、累计成交、目标剩余量与 reservation，不含 Venue 字段或 Adapter 调度。

- place、原地 amend、cancel 共享同一订单状态机；revision、累计成交与预期身份不匹配时失败关闭。
- `TransportBatch` 的每项 dispatch 结果独立推进；`Independent` 保留其他项，`CancelRemaining` 停止未发送项并取消已提交项。
- `Unknown` 保留最坏情形 reservation，只有权威执行回报或显式 reconciliation 才能解除。
- 非原地 amend 仅在显式授权后执行 CancelConfirmCreate；旧订单到达终态前不创建替代订单，新身份记录 predecessor 且重新占用 reservation。
- 执行回报和对账结果按稳定身份做语义幂等；终态不回退、冲突重复失败关闭。
- OMS 状态、reservation、回报/对账身份和下一身份计数均进入当前 `CanonicalStateDigest`，实时与重放经过相同 `apply(CanonicalEvent)` 路径。
- TDD 复审补证：SPOT/SWAP 各有多个订单分别完成 place/amend/cancel；所有失败输入在整个 `TradingShard.apply` 上原子不变；终态不被 reconciliation 回退；全部已见 report/reconciliation identity 持续检测语义冲突；CancelConfirmCreate 可由执行回报或显式 reconciliation 确认，并按最新事实重新风控。

风险金额的分层计算留给第 04 票；本票已经保证由风险层提供的 reservation 在 amend、Unknown、终态和替代订单之间不被提前释放或重叠占用。
