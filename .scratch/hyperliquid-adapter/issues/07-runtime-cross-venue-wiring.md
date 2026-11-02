# 07：运行组装与跨所接线

Type: task
Status: open
Assignee:
Blocked by: [04 公共行情](04-public-market-feed.md), [06 对账与恢复](06-reconciliation-recovery.md)
Parent: [模块地图](../map.md)

## Question

如何通过已有运行入口和控制面使用 Hyperliquid，并让现有两腿策略消费其规范能力？

## What to build

在现有 runtime、配置登记与构建入口组装 Adapter，复用 Web 控制面、Owner、账户路由及 StrategyHost。核对现有跨所策略的 USDT 限定，只补齐同结算资产 USDC—USDC 支持，不重写策略。

## 完成条件

- [ ] 登记 Venue/环境/账户/品种、资产规则和真实 capability；缺失能力拒绝，能力刷新不恢复已撤销的交易授权。
- [ ] 两腿只允许相同报价/结算资产，现货包装资产保留身份且有明确批准的经济配对；不加入稳定币兑换或跨资产抵押。
- [ ] 既有共同准入、预留、双 IOC、Maker–Taker 撤旧后新建及周期恢复贯通；内部原子性不冒充外部成交原子性。
- [ ] 默认入口离线且不加载真实凭证；只读、Testnet 写入和生产权限隔离，不能套用其他 Venue 的 Demo 开关。
- [ ] 账户配置读写接口按已有控制授权边界接入；若确需新增写入合同，先列明通用请求和调用方影响，禁止任意 Venue API 透传及 Adapter 自主改杠杆。
- [ ] 复用 src/entry.zig、tools/zig-entry.py 和既有离线编排；更新配置说明、能力/字段矩阵和必要调用脚本，不建立第二套 runner/CLI。
- [ ] 经实际运行组装验证隔离、旧 session、权限失效、单腿失败及 Unknown；既有 Venue 回归通过，离线双腿证明与在线资格分开。

## Answer

尚未开始。
