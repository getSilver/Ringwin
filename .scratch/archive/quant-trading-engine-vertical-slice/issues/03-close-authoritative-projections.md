# 闭合订单、双层仓位、账本与定点风险

Type: implementation
Status: resolved
Blocked by: 02
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

如何在 walking skeleton 中补齐权威经济状态，使每个不可变事实都能确定地推导订单、PortfolioPosition、ExchangePosition、风险占用、双层账本、费用和移动加权平均 PnL？

## Scope

- 复用已验证的定点保证金算法和既有账务规则，不复制交互演示代码。
- OrderState 继续是命令与回报事实的派生投影。
- 成交同时更新唯一 VirtualPortfolio 归属、ExchangeAccount 净仓位及对应账本交易。
- 手续费、已实现/未实现 PnL、保证金预留与释放必须逐分量精确闭合。
- StateDigestV1 覆盖全部权威投影，但不包含可推导缓存或展示格式。

## Done when

- happy path 的每个预期经济值与第 01 票 fixture 完全一致。
- 全部权威计算中不存在 `f32`、`f64` 或隐式浮点转换。
- 账本借贷闭合、双层仓位闭合和风险占用释放均由自动检查验证。

## Answer

- [`src/main.zig`](../../../src/main.zig) 现以 Fill 作为唯一经济触发事实，同步推导 OrderState、PortfolioPosition、ExchangePosition、移动加权 OpenCost、手续费账务、风险占用及 PnL。
- 定点函数使用 i64 状态与 i128 中间值，按微 USDT 向增加风险要求方向取整；源码扫描不存在 f32、f64 或隐式浮点转换。
- 第一笔成交后自动断言：双层仓位 40、OpenCost `199.600000 USDT`、手续费 `0.149700 USDT`、PositionMarginRequirement `4.400000 USDT`、OpenOrderReservation `6.838650 USDT`。
- 最终自动断言：双层仓位 100、OpenCost `500.200000 USDT`、手续费 `0.375150 USDT`、UnrealizedPnL `1.800000 USDT`、OpenOrderReservation 0、PositionMarginRequirement `11.044000 USDT`、RiskLease remaining `9,988.956000 USDT`。
- VirtualPortfolio、TreasuryPortfolio 与 ExchangeAccount 的现金余额精确闭合；OpeningBalance、PortfolioTransfer 和两笔手续费对应的两层借贷累计额分别自动闭合。
- happy path 已补齐冻结的 31 条权威事实，包括 OrderDispatchResult、两笔手续费 LedgerTransaction 和两次风险占用重算。
- StateDigestV1 使用 Zig 标准库 SHA-256 和稳定小端整数编码，覆盖规则版本、L2、策略游标、订单、双层仓位、账本、PnL 和风险状态；固定摘要为 `2d374b99264f82d6b218bff68a7f2ea81e9a1b26202849d5b39afc79eab2fabf`。
- `zig test src/main.zig -O ReleaseSafe` 与 `zig run src/main.zig -O ReleaseSafe` 均执行相同 happy-path 自检。

## Comments

- 2026-07-30：已认领；开始补齐 happy path 的定点经济投影与闭合自检。
- 2026-07-30：31-event happy path、定点经济终态、双层账本/仓位/风险闭合和固定 StateDigestV1 全部通过；票据解决。
