# 闭合四分片与共享账户协调

Type: task
Status: closed
Assignee:
Blocked by: 07
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何让四个单写者 TradingShard 在共享 Execution Gateway 和 ExchangeAccount 下保持确定性归属、全局额度租约、GrossPortfolioMargin/VenueNetMargin 核对、账户事实扇出与局部故障隔离，且不复制 Venue 接入或让任一分片消费 AccountNettingBenefit？

## Acceptance

- [x] 稳定协议固定 shard/account/summary/fact/barrier 身份，冲突、乱序、跨分片与缺失输入失败关闭。
- [x] 协调器只根据 GrossPortfolioMargin 分配可重放 RiskLease；AccountNettingBenefit 仅作核对事实，不进入任一 shard 可用额度。
- [x] 账户/Venue 事实按稳定顺序扇出，margin 差异锁存 ReconciliationBreak/SafetyGate，共享 Gateway 只向唯一订单所有者路由结果。
- [x] 局部 gap/overload 只冻结对应 DecisionDomain；账户 lease、margin 与 gateway 故障会向下收紧全部 shard。
- [x] coordinator snapshot + 持久 tail 与四个 shard snapshot + 非空 tail 在 RecoveryOnly 中恢复，覆盖成功、失败和途中再崩溃路径。
- [x] 全量重放、snapshot-tail 恢复与实时执行收敛到同一 coordinator/shard 摘要；恢复类型不持有 Gateway 或历史发送能力。

## Evidence

- 实现提交：`7977ed2` 引入协调器持久 tail，并闭合四分片恢复验收。
- `tools/verify-core-wave.ps1`：Debug/ReleaseSafe 各 111 项通过，四分片 schema 1 摘要固定并通过恢复等价检查。
