# 08 从机会页将一条路线加入指定策略

Type: task
Status: resolved
Assignee:
Blocked by: [06 在机会页给出可复算的交易潜力](06-evaluation.md)、[07 跨所策略以空交易名单启动](07-empty-list.md)
Parent: [模块地图](../map.md)

## Question

点击加入后核心究竟批准哪一条路线？

## What to build

在正常前端选择 StrategyInstance 与 VirtualPortfolio，将候选映射到部署账户和品种，回显核心回执。

## 验收条件

- [x] 同币多路线中仅所选双腿、方向及模式进入指定策略名单。
- [x] Demo × Testnet 分别映射各自环境、账户和品种；观察来源与真实账户可独立核对。
- [x] 现行评估过期、映射缺失或批准被拒时显示原因，页面状态与核心一致。

## 实现与证据

机会详情从 engine 选择 StrategyInstance 与 VirtualPortfolio。提交绑定页面所见的评估和两腿选择。正式 Writer 根据部署归属解析账户与 Instrument，并以核心版本及持久化屏障确认批准。详情同时展示观察来源和交易腿，待确认请求保留原请求身份。部署和映射合同见[扫描运行手册](../../../docs/scanner-runtime.md#从机会页批准交易路线)。

- Windows 离线联合验收贯通认证 HTTP、支持批准的中继和 Zig Writer 探针。用合成 OKX Demo × Hyperliquid Testnet 观察、两条同币路线和两个策略实例，选择观察品种 201 × 102，将其映射为账户 20／品种 103 和账户 30／品种 102。实际第一腿公共行情标为 production，观察命名空间为 701 × 702。策略 9／组合 10 的名单只含所选双 IOC 路线，策略 19／组合 11 的名单为空，交易授权保持关闭。
- 认证 HTTP 回归覆盖缺失映射、CSRF、请求重试，以及同一候选由新评估替换前后拒绝旧引用。Zig 定向回归覆盖反方向、Maker 能力拒绝、错误组合、持久化恢复和原身份取回回执。
- 通过 4 项定向 Python 回归、Zig 正式 engine 与配对批准过滤测试、前端 TypeScript 类型检查和两个扫描器检查。正式 Linux engine 入口已定向交叉编译。联合测试使用离线 Writer 探针和合成输入，真实场所及正式 Linux 进程运行留待后续验收。前端提交为 RingwinUi `ea14513`、`919b761`。
