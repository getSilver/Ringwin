# 在 Linux 闭合 Binance Testnet 在线链路

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 启动可安全排空的 Linux 生产进程链](02-run-linux-production-process-chain.md), [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md), [04 通过 CredentialStore 完成只读安全准入](04-unlock-credential-and-pass-security-admission.md)
Parent: [Linux 生产资格收口](../map.md)

## Paused

2026-09-17 活链因无 Testnet 密钥暂缓。required/verified 拆分与 Binance wire 编码修正在
[Windows 进程链验证票 02](../../windows-process-chain-verification/issues/02-split-binance-bybit-capability-evidence.md)；
该预备工作不能把本票标为 resolved，也不能写入 `TestnetQualified`。

## Question

如何把当前 Binance 合约实现接到真实 Linux REST/WSS transport，并通过 Spot 与 USDT 线性永续
Testnet 证明所有成功、拒绝和结果不明路径都保持同一核心语义？

## What to build

实现 Binance Linux 在线 transport owner、连接生命周期和资格 runner；复用现有 VenueAdapter、
MarketFeedAdapter、RawIngress、私有对账和 Gateway seam，完成 Testnet 受限订单与清理闭环。

## Acceptance criteria

- [ ] 执行时重新核对当前官方 Testnet endpoint、签名、权限、listen key/会话、限流和产品规则。
- [ ] Spot 与 USDT 线性永续的产品、账户模式、InstrumentRules、MarginRules 和 CapabilityProfile 明确分离。
- [ ] 支持矩阵分别记录目标 required capability 与当前 verified capability/evidence；真实 transport 和 Testnet 尚未验证的 native amend、post-only 或 batch 不得出现在已验证投影。
- [ ] Spot 与永续的真实 HTTP method、path、参数位置和签名输入逐 endpoint 编码；通用 `operation` 字段不得冒充 Binance wire contract。
- [ ] REST bootstrap 与 WS 增量按来源顺序闭合订单、成交、余额、仓位、账户配置和行情事实。
- [ ] HTTP 429/418、5xx、timeout、半写、损坏/缺项响应和断线按 NotSent/Submitted/Unknown 分类；Unknown 永不自动重发。
- [ ] place/amend/cancel、逐项 batch、部分成功、部分/完整成交、费用、资金费和重复/乱序事实均可确定性重放。
- [ ] Testnet 写运行必须具备明确授权、无提现权限、固定名义上限和预先武装的清理路径。
- [ ] 每次运行结束零残余挂单、零仓位/负债、零未解释 Unknown，账户与双层经济投影闭合。
- [ ] Binance 故障或限流不会关闭无共享依赖的 OKX/Bybit Venue 或 TradingShard。
- [ ] 生成独立 `TestnetQualified` 报告；没有真实运行时状态保持 `not_run`。

## Out of scope

- Binance 生产资金写入；由最终 Canary 票单独授权。
- 币本位、组合保证金、双向持仓和未冻结订单能力。
