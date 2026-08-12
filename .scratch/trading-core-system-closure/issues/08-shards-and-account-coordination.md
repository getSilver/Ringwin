# 闭合四分片与共享账户协调

Type: task
Status: open
Assignee:
Blocked by: 07
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何让四个单写者 TradingShard 在共享 Execution Gateway 和 ExchangeAccount 下保持确定性归属、全局额度租约、GrossPortfolioMargin/VenueNetMargin 核对、账户事实扇出与局部故障隔离，且不复制 Venue 接入或让任一分片消费 AccountNettingBenefit？
