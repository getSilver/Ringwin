# 在 Linux 闭合 Bybit Testnet 在线链路

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 启动可安全排空的 Linux 生产进程链](02-run-linux-production-process-chain.md), [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md), [04 通过 CredentialStore 完成只读安全准入](04-unlock-credential-and-pass-security-admission.md)
Parent: [Linux 生产资格收口](../map.md)

## Paused

2026-09-17 活链因无 Testnet 密钥暂缓。required/verified 拆分在
[Windows 进程链验证票 02](../../windows-process-chain-verification/issues/02-split-binance-bybit-capability-evidence.md)；
该预备工作不能把本票标为 resolved，也不能写入 `TestnetQualified`。

## Question

如何把当前 Bybit 合约实现接到真实 Linux REST/WSS transport，并在不把 Demo 局限误当生产行为的
前提下取得 Spot 与线性永续 Testnet 资格？

## What to build

实现 Bybit Linux 在线 transport owner、UTA 账户 bootstrap、私有/公共连接生命周期和资格 runner；
经既有 adapter seam 完成 Testnet 订单、成交、对账、恢复和清理闭环。

## Acceptance criteria

- [ ] 执行时重新核对当前官方 Testnet/Demo/Mainnet endpoint、key 类型、签名、权限、账户模式和限流。
- [ ] Testnet 与 Demo 资格严格分开；Demo 缺失的功能不得由 fixture 或 Testnet 结果推断为生产支持。
- [ ] 无初始 WS snapshot 的账户事实必须以 REST 建立 bootstrap，并证明缓冲增量与分页读取顺序。
- [ ] Spot 与线性永续的订单、成交、wallet、position、MarginRules 和 CapabilityProfile 映射完整。
- [ ] 支持矩阵分别记录目标 required capability 与当前 verified capability/evidence；只有 fixture/contract test 的 native amend、post-only 或 batch 保持未验证。
- [ ] 所有 RawIngress frame 使用统一有界大小合同；任一公共或私有 feed 都不能省略全局 raw frame 上限。
- [ ] place/amend/cancel、逐项 batch、部分成功、费用、资金费、断连、限流、timeout 和 Unknown 均通过统一 seam。
- [ ] Testnet 写运行必须具备明确授权、无提现权限、固定名义上限和预先武装的清理路径。
- [ ] 每次运行结束零残余挂单、零仓位/负债、零未解释 Unknown，账户与双层经济投影闭合。
- [ ] Bybit 故障不破坏无共享依赖的 OKX/Binance Venue 或 TradingShard。
- [ ] 生成独立 `TestnetQualified` 报告；没有真实运行时状态保持 `not_run`。

## Out of scope

- Bybit 生产资金写入；由最终 Canary 票单独授权。
- 期权、组合保证金、双向持仓和未冻结 UTA 能力。
