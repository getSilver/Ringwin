# 在 Linux 闭合 OKX Demo 在线链路

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 启动可安全排空的 Linux 生产进程链](02-run-linux-production-process-chain.md), [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md), [04 通过 CredentialStore 完成只读安全准入](04-unlock-credential-and-pass-security-admission.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何在 Linux 生产进程、真实 DurableStore 和 CredentialStore 上重新取得 OKX Demo 在线资格，并
证明生产 endpoint 的只读路径与 Demo 写路径不会互相提升资格？

## What to build

把现有 OKX REST/WSS、公共行情、私有对账和订单能力接入 Linux role 进程。以 ObservationCredential
验证生产只读准入，以独立 Demo ExecutionCredential 在明确 SystemOwner 授权后完成受限订单闭环；
两种运行生成不同且不可互换的 QualificationReport。

## Acceptance criteria

- [ ] 执行时重新核对当前官方 endpoint、区域域名、权限、时间、限流、账户模式和字段处置。
- [ ] Demo 与 production 的 endpoint、header、CredentialState、RunMode 和资格类型不能组合错误。
- [ ] 公共行情、私有 bootstrap、REST 双读、WS 缓冲、订单/成交/余额/仓位和 RawIngress 在 Linux 进程链贯通。
- [ ] place/amend/cancel、部分/完整成交、费用、返佣、超时 Unknown、限流和断连恢复经统一 VenueAdapter seam。
- [ ] 写请求只能在 Demo、明确授权、最小名义上限、有效凭证、完整 SafetyGate 与已武装清理同时成立时发送。
- [ ] 每次 Demo 写运行前后证明零残余挂单、零未解释 Unknown、仓位/库存恢复且账务对账闭合。
- [ ] 生产只读运行 `writes_sent=0`，只取得 Observation 证据，不能被标记为生产交易合格。
- [ ] live 与 semantic replay 对同一规范事实产生相同 CanonicalStateDigest，replay 没有发送能力。
- [ ] 资格报告绑定 ReleaseArtifact、节点、账户、凭证版本、CapabilityProfile 和原始证据哈希。

## Out of scope

- OKX 真实资金订单；由最终 Canary 票单独授权。
- 非支持产品、算法单和账户/资金管理端点。

## 当前执行记录（2026-09-07）

已实现 Linux 原生验收入口 `tools/run-okx-linux-acceptance.ps1`：它使用
`x86_64-linux-gnu` ELF、锁定的 libcurl 8.21.0/OpenSSL transport、`.env.local` 中的 Demo
凭证变量和显式 global Demo endpoint profile；凭证值不进入参数或输出。`src/okx_curl_shim.c`
的运行时 probe 现在在 Windows 要求 Schannel、在 Linux 要求 OpenSSL，并继续要求 HTTPS/WSS。

本机 Linux 构建成功，原生进程已完成 libcurl runtime probe 并进入 OKX Demo private WSS；随后
WSL1 网络出口对官方 `wss://wspap.okx.com:8443/ws/v5/private` 的 TLS 握手返回
`SSL_ERROR_SYSCALL`，因此本次 `PrepareOnly` 资格运行失败关闭。该结果不构成在线资格证据，不能
把票据标记为 resolved。官方 endpoint、Demo header、认证和限流规则已于本次运行重新核对：

- REST：`https://openapi.okx.com`，Demo REST 请求带 `x-simulated-trading: 1`。
- Private WSS：`wss://wspap.okx.com:8443/ws/v5/private`。
- 下单权限仍为 Trade；place/amend/cancel 单请求限流为 60 requests/2 seconds，且共享相关
  REST/WS 交易限流桶；`50011`/`50061` 必须保留为原始限流事实。

尚未执行 `DemoLive`：按生产 readiness 规则，`.env.local` 提供凭证不等于本次
SystemOwner 下单授权。要关闭本票，还需要在具备官方 WSS 出口的 Linux 节点重新跑
`PrepareOnly`，再由 SystemOwner 明确授权 `DemoLive`，完成真实受限订单、清理、对账和
live/replay digest 证据。
