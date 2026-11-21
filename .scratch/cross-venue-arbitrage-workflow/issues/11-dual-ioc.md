# 11 从前端批准跑通双 IOC 完整周期

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [05 USDT/USDC 平价估值与汇差归因](05-stablecoin.md)、[08 从机会页将一条路线加入指定策略](08-approve.md)、[10 让策略限价准确到达 Gateway](10-limit-price.md)
Parent: [模块地图](../map.md)

## Question

同一笔人工批准能否贯穿一次完整开平仓？

## What to build

从空配置经正式前端扫描、批准、开仓前复核和双腿路由，追踪同一策略周期直到退出对账。使用 [08](08-approve.md) 提供的可信账户绑定，将 [04](04-fees.md) 的当前费率源接入正式 StrategyHost，在批准路线的开仓前复核两腿费率版本。

## 验收条件

- [ ] 使用实际运行组装，逐腿核对账户、产品、环境、方向、最终价格、数量与原始订单身份。
- [ ] 用同一条已批准路线验证费率更新后的正式开仓复核。旧版本或缺少任一腿费率时不得产生开仓动作；当前版本通过费率复核后继续走既有准入及双腿路由。
- [ ] 双腿成交后核对持仓与退出，原币费用、返佣及独立汇差与周期账务一致。
- [x] 记录测试环境、场所、输入及回执来源，区分离线、Demo/Testnet 与实盘证据。

## 进展

- Admission、准入交接和首笔开仓动作从磁盘读取已发布的人工费率。每批准入共享同一份快照，交接和首笔开仓分别复核当前版本及两腿的场所、账户和产品。策略 checkpoint 保留费率版本对应的场所。旧 checkpoint 若只有费率版本且仍处于空闲，须重新准入以建立完整费率绑定。
- Python 回归使用两个独立的费率读写实例，覆盖更新后拒绝旧版本、版本相同但缺腿、两腿齐全后继续准入，并验证已恢复的周期在拒绝时保留空闲状态和原意图序号。
- Windows 离线定向集成使用 Zig ReleaseSafe、两个合成场所（Venue 1 × 21，环境均为 simulation）、账户 20 × 30 和品种 101 × 102。公共盘口来自 canonical 深度夹具，费率从临时状态目录读取，批准条件由 Python 夹具提供。同一 ManagedHost 对旧版本与缺第二腿版本均未发布开仓帧，当前完整版本经 Writer 生成双 IOC，模拟 Gateway 捕获买入 100 ticks 和卖出 110 ticks、各 10,000 lots，并与 OMS 的订单 ID 和客户端订单 ID 一致。合成回执经持久化后恢复到 holding。未使用 Demo/Testnet 或实盘连接。
- 正式 Linux Host 当前在 pipe 边界消费输出，未将其交给 Writer 及 Gateway。仍需通过正式运行组装绑定 Web 批准、当前费率、双腿成交和退出对账。保留本票为 Frontier，[12](12-ioc-recovery.md) 和 [13](13-maker.md) 仍依赖本票。
