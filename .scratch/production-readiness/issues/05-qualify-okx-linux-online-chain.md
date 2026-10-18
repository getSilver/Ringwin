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
- [ ] Demo 写链使用独立 Demo ExecutionCredential，经 CredentialStore 或继承的受限 fd 注入受保护内存；API key、secret 和 passphrase 不再通过进程环境传播。
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

此前尚未执行 `DemoLive`：按生产 readiness 规则，`.env.local` 提供凭证不等于本次
SystemOwner 下单授权。现在授权已补齐，但要关闭本票仍需要在具备官方 WSS 出口的
Linux 节点重新跑 `PrepareOnly`，再完成真实受限订单、清理、对账和 live/replay
digest 证据。

追加执行记录（2026-09-07）：SystemOwner 已明确授权 Demo 下单，并实际运行
`tools/run-okx-linux-acceptance.ps1 -Mode DemoLive -SystemOwnerAuthorized`。运行在
`establishReady` 的 private WSS 连接阶段失败，原始 Linux 输出为
`error: WebSocketTransport`；对应底层无凭证分层探针为：WSL1 DNS 能解析
`wspap.okx.com`，`https://openapi.okx.com` 连接超时，官方 private WSS 的 8443 和
443 TLS 均返回 `SSL_ERROR_SYSCALL`。`example.com` 在同一 WSL1 中可达，因此不是
WSL1 完全断网。Windows 默认代理对 REST 可达且对 WSS 443 返回 HTTP 400，但代理仅
监听 Windows `127.0.0.1:7890`，WSL1 无法连接该回环代理；将该代理传给 Linux 入口
仍在 WSS 阶段失败。

本次 DemoLive 没有进入第一次 `dispatch`，没有发送订单；DemoLive 与无写入
`PrepareOnly` 均失败关闭。本票仍为 `ready-for-agent`，未取得 Demo 在线资格，
生产资格保持 false。需要在具备官方 WSS 出口的 Linux 节点，或提供 WSL1 可达的
代理/网络出口后重新运行。

Windows 功能性分流验收（2026-09-07）：为区分 Venue/API 功能与 Linux 运行环境，先用
现有 Windows 路径验证官方 443 Demo WSS。`tools/okx-demo-private-readonly.ps1`
对 `wss://wspap.okx.com/ws/v5/private` 登录成功，`orders`、`account`、`positions`
订阅成功，账户快照 1 行、仓位快照 0 行、`writes_sent=0`。随后在显式
`tools/okx-demo-live-postonly.ps1 -DemoLive -SystemOwnerAuthorized`
通过：`BTC-USDT` 受限
`post_only place/cancel`、最大名义 25 USDT、`cleanup=verified`、`filled=false`。
这证明 Windows 下 Demo WSS、认证、REST 写入和撤单清理功能可用，但不替代 Linux
生产运行链资格；票据仍保持 `ready-for-agent`，生产资格保持 false。

## 目标 Linux 在线执行（2026-09-21）

- 目标 Debian 节点已通过 OKX REST、Demo private WSS 443 登录/订阅、账户/订单/成交/账单双轮
  bootstrap、public instruments REST 初始化及 public WS 行情衔接；`PrepareOnly` 只读运行通过。
- 在线执行修复了真实响应暴露的账户小数保守量化、零仓位 margin 接受、WS ping/pong、instrument
  初始化、整数 seqId/prevSeqId 与非连续但 predecessor 相连的 book sequence，以及 canonical
  `limit + IOC` 到 OKX `limit_ioc` 的映射；Debug/ReleaseSafe 全量回归均退出 0。
- Demo 写运行始终在外部效果前失败关闭，账户复核持续为 `btc_zero=true`、`nonzero_positions=0`、
  `pending_orders=0`。当前 OKX Demo 模拟盘口卖一约 `86199.7`，同一 Demo 的 `buyLmt` 约
  `85447.9`，不存在满足价格带且可成交的买价，程序返回 `NoExecutableBuyPrice`，未绕过保护。
- 凭证仍由用户指定的 `env.local` 注入进程环境，且 place/amend/cancel、成交/费用、Unknown/限流/
  断连、live/replay digest 与资格报告尚未完整闭合。本票保持 `ready-for-agent`，生产资格为 false。

### 价格带恢复后的单次受限重试（2026-09-21）

- 同一 Demo header 下重新探测得到 ticker/book ask `85893.6`、`buyLmt=86357.7`，满足
  `ask <= buyLmt`；恢复 runner 内的 `protectedBuyPrice`/`protectedSellPrice` 后，仅执行一次
  Linux ReleaseSafe DemoLive；新增价格带边界回归，Debug/ReleaseSafe 各 `251/251` 通过。
- BTC-USDT `limit_ioc` 买单 `0.00005 BTC` 在 `85893.6` 全量成交，OKX 返回 filled，手续费为
  `0.00000005 BTC`。但程序在私有流等待窗口内没有取得可用于 `currentNetBtc` 的余额事实，返回
  `BuyDidNotFillMinimum`，因此不能把该运行记为完整成交/清理资格。
- 同一 durable state 的恢复清理先暴露旧状态 `TraceFull`，新状态随后暴露
  `IdentityOutOfRange`；后者需要在 canonical private event 到 TradingShard 的身份边界捕获精确事件，
  当前 `u128` canonical identity 到 OMS/economics `u64` 的收窄路径不能被视为已合格。
- 为避免残留风险，使用独立受限应急清理按目标机实时 `lotSz=0.00000001` 精确卖出扣费后的
  `0.00004995 BTC`，IOC 价格 `85815.1`。最终独立账户复核为 `btc_zero=true`、
  `liability_zero=true`、`nonzero_positions=0`、`pending_orders=0`；systemd target 仍为
  disabled/inactive。
- 本轮证明 Linux 内部路径已真实发送并取得一次 Demo fill，但没有证明内部自动清理、恢复后身份、
  live/replay digest 与不可变 QualificationReport；不再循环下单，本票继续保持 `ready-for-agent`，
  production qualification 仍为 false。

### 在线失败后的源码修复（2026-09-21）

- OKX 私有成交/账单摘要生成的 canonical identity 现在限制在既有 OMS/economics `u64` 权威边界内，
  消除恢复对账的 `IdentityOutOfRange`；完整 SHA-256 仍保留在 raw evidence/digest 中。
- 订单终态先于账户事实到达时，验收入口会复用既有双轮私有 REST 对账并重新 drain canonical 输出，
  不再仅因 12 帧 WS 窗口内缺少余额观察而误报 `BuyDidNotFillMinimum`/`CleanupUnconfirmed`。
- 不扩大 Trace 或变更快照 schema；恢复和每次外部订单效果前预留固定 Trace 容量，不足时以
  `InsufficientDemoTraceCapacity` 在发送前失败关闭，避免旧状态在外部效果后才暴露 `TraceFull`。
- 新增三个最小回归点；`zig test src/main.zig -ODebug` 与 `-OReleaseSafe` 均为 `252/252`，
  `zig test src/okx_demo_live_acceptance.zig -ODebug` 为 `62/62`。本轮未再次发送 Demo 订单，
  所以自动买入/清理、live/replay digest 和 QualificationReport 仍待一次明确授权的 Linux 在线复验；
  本票保持 `ready-for-agent`，production qualification 仍为 false。

### 修复后的在线复检（2026-09-22）

- 目标端复检前保持 systemd target `disabled/inactive`、无资格进程，账户为零 BTC、零负债、零仓位、
  零挂单；Demo ticker/book ask 为 `85909`，`buyLmt=86265.4`，价格带允许一次受限尝试。
- 校验 ReleaseSafe v36 哈希后仅执行一次 DemoLive。BTC-USDT IOC 买单 `0.00005 BTC @ 85909`
  全量成交，手续费 `0.00000005 BTC`；身份宽度修复未再出现 `IdentityOutOfRange`。
- 终态后的 REST 回补暴露更精确的状态机缺口：初次 bootstrap 已使 Reconciler 进入 `ready`，但
  `beginReconciliation` 仅接受 `buffering`，未开启新一轮显式账户对账便直接 ingest REST，因而返回
  `invalid_field`，上层仍报 `BuyDidNotFillMinimum`。
- 旧 Demo 余额调整工具被 OKX 以 `51000 Parameter amt error` 拒绝，未改变账户；随后使用受限 IOC
  精确卖出扣费后的 `0.00004995 BTC @ 85648.7`。独立最终复核再次为零 BTC、零负债、零仓位、零挂单，
  systemd target 仍为 `disabled/inactive`，无残留资格进程。
- 源码已允许 `ready` 私有流显式重启稳定双读，并在订单终态回补前通过 VenueAdapter 发起新的
  `account_reconciliation`。新增状态机回归后，主套件 Debug/ReleaseSafe 均为 `253/253`，Demo
  ReleaseSafe 为 `63/63`。本轮授权的唯一买入尝试已经用完，未用新修复再次下单；票据和生产资格
  状态不变。

追加授权复检：SystemOwner 随后明确授权一次 v37 Demo 写复验。目标端再次通过二进制哈希、零敞口、
服务停用及价格带守卫（ask `85941.9`、`buyLmt=86323.7`）；IOC 买单 `0.00005 BTC @ 85941.9`
全量成交并扣除 `0.00000005 BTC` 手续费，但首个 REST 回补仍返回 `invalid_field`，程序再次以
`BuyDidNotFillMinimum` 失败关闭。这证明 `ready -> reconciling` 放宽及显式 account reconciliation
仍未闭合真实调用链，v37 不能视为在线通过。用户停止清理指令到达前，应急 IOC 已精确卖出
`0.00004995 BTC @ 85757.9`；最终独立复核为零 BTC、零负债、零仓位、零挂单。此后停止全部远程
写操作，不再自动下单或清理。

追加 v38 复检：修复 ready-mode 私有 WS 事实跨 VenueAdapter canonical seam 后，主套件
Debug/ReleaseSafe `254/254`、Demo ReleaseSafe `65/65`；目标端通过工件哈希、零敞口、服务停用和
价格带守卫（ask `86097.2`、`buyLmt=86479.4`）后执行一次授权 DemoLive。IOC 买单
`0.00005 BTC @ 85964.9` 全量成交并扣除 `0.00000005 BTC` 手续费，随后 TradingShard 返回
`InvalidFill`：同一 OKX 私有事实中的 execution report 已把 OMS cumulative 更新到完整数量，紧随的
canonical fill 又以 `order.cumulative_quantity + fill.quantity` 校验，从而把报告已反映的成交重复计入
上限检查。当前独立复核为零负债、零衍生仓位、零挂单，但 BTC 非零；依 SystemOwner 先前指令不再
自动清理，等待人工清理。不得继续买入或提升资格状态。

### 本地 Venue 成交恢复证据追加（2026-09-23）

`venue-fill-recovery` 离线修复波封存了机器可读证据：根套件 Debug/ReleaseSafe 各连续三轮
`264/264`，`x86_64-linux-gnu` ReleaseSafe 仅编译（`--test-no-exec`）通过，single/four-shard
barrier、digest 与 no-send 断言均通过。该波含 OKX raw
`ingestPrivateWs → tryDrain → Owner.applyAdapterBatch → DurableStore → recovery` fixture，且未访问
凭证或 Venue endpoint、未执行 Demo/Testnet/production 写入。

此记录仅为本地离线证据，**不改变本票 `ready-for-agent` 或
`ProductionQualified=false`**，也不消除 v38 后 BTC 人工清理边界。下一次 Linux 在线复验仍需
SystemOwner 重新明确授权，并先重新核对账户残余、服务状态和目标节点网络条件。

### v39 在线复检（2026-09-23）

SystemOwner 再次明确授权一次有界 Demo 写复检。当前源码以 economic projection 的已应用
canonical Fill 数量校验 overfill，并新增 report/fill 合法顺序矩阵；主套件 Debug/ReleaseSafe
均为 `264/264`，Demo ReleaseSafe 为 `111/111`。目标端二次预检确认零 BTC、零负债、零衍生
仓位、零挂单，systemd target `disabled/inactive`，ask `86330.7` 小于 buyLmt `86762.2`。

v39 在 `phase=private_stream ok` 后、任何新订单发出前以 `RestBootstrapRejected` 退出。stderr 的
两个诊断被随后写入覆盖，但直接运行 `prepare-only` 的完整输出对应 `rest_fills_history_spot` 与
`conflicting_fact`；因此新的在线阻塞位于历史 SPOT fill 的稳定 REST bootstrap，而非已修复的 TradingShard
report/fill 重复计量。独立最终核验仍为零 BTC、零负债、零衍生仓位、零挂单，未发送清理单或
第二笔买单；票 05 与 `ProductionQualified=false` 保持不变。
