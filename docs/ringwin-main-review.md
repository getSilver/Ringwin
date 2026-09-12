# RingWin `main` 代码审查

范围：本机 `D:\github\Ringwin` 当前 `main`（复核基线 `af9634084e6e869803d6cde3610a768c73b43ced`；`src/` 无未提交修改）

验证：`zig build test --summary all` 通过，214/214；该结果只证明现有回归通过，不覆盖本文指出的全部生产安全不变量。

修复跟踪：[收口当前 main 安全与权威状态缺口](../.scratch/main-safety-remediation/map.md)。

## 2026-09-10 离线修复结果

本审查列出的 H1、H2、M1、M3、M5 和多数核心业务逻辑缺口已有离线修复；2026-09-12 最终 Spec 复核发现
OMS 原生 DispatchProof、崩溃前持久发送事实及墓碑归档资格仍未收口，以上本地图已恢复 `active`，不得宣称本波完成。新的验收合同固定为
report schema 3、journal/state schema 9，并以同一输入矩阵运行 Debug 与 ReleaseSafe；源码 revision、精确 Zig、
测试数、barrier、digest、Gateway 发送计数和失败关闭断言由 `tools/verify-core-wave.ps1` 从子验收输出推导。

StrategyHost 产品链不再向 Python 传递共享内存、fd、mapping handle、指针或原子游标；Zig supervisor 在有界 framed bridge
两端校验并复制 input/output bytes。独立 ring 实现仍保留为 Zig 内部有界设施，Linux backing object 固定尺寸并
sealed，但它不再是 Python 的能力。

这次结果只恢复离线核心可信基线，不改变生产资格：M2 继续由
[生产进程链](../.scratch/production-readiness/issues/02-run-linux-production-process-chain.md)、
[Web 生命周期](../.scratch/production-readiness/issues/08-operate-and-deploy-signed-release.md)和
[NodeFence](../.scratch/production-readiness/issues/10-fail-over-with-lease-and-node-fence.md)跟踪；M4 由 Web 生命周期跟踪；
M6/M7 由[凭证准入](../.scratch/production-readiness/issues/04-unlock-credential-and-pass-security-admission.md)及
[OKX Linux 在线链](../.scratch/production-readiness/issues/05-qualify-okx-linux-online-chain.md)跟踪。Linux 在线 Venue、
Testnet、真实资金和 ProductionQualified/Canary 均仍为 `not_run`。

以下正文保留 `af96340` 基线的原始发现与修复依据；其中“必须修”的缺口不再代表修复后源码现状。

总评：这是一套纪律很强的**确定性交易核心原型**，fail-closed 意识明显优于一般量化代码。但它还不是可上实盘资金的引擎。领域模型（`CONTEXT.md`）比运行时更完整；五进程生产链、凭证、持久化、故障切换大多是**独立缝合面**，没有接到真正的下单回路。

---

## 1. 架构是否合理

合理的部分值得保留：

- 单一写入入口：`TradingShard.apply` 同时接纳核心事件和 Venue 规范事件，成功才提交。
- 策略只产 `OrderIntent`，风控 / OMS / 账本在 Zig 核心。
- Venue 执行与公共行情拆成两个 seam（ADR 0001），核心不吃交易所字段。
- 定点整数、账本守恒、未知订单锁存、Replay 不能发送。
- 生产资格谓词诚实：Demo/Testnet 不能升级成 `production_qualified`。

不合理或未完成的部分：

**运行时拓扑是草图。** `main.zig` 没有默认交易入口。`--production-role` 五个角色（engine / market-feed / execution-gateway / telemetry / control-fence）只做 1 字节 Unix 控制帧，不构造 `TradingShard`、适配器、日志或凭证。注释写得很清楚：本模块只拥有进程生命周期。systemd unit 也只保护这个空壳。

**`TradingShard` 是真分片，也是上帝对象。** 它是单写决策域，但内部同时拥有 OMS、风控、账本、操作态、行情投影、账户投影、原生 timer 策略、快照、journal。`oms.zig` / `risk.zig` / `economics.zig` 已经拆出，分片仍是 2400 行总开关。

**边界编码合理，重复业务所有权不合理。** `canonical_event.zig` 的适配器事实、`trading_shard_event.zig` 的分片输入/日志事实和 `strategy_host_gateway.EventType` 的有界 IPC 编码服务于不同边界，不应仅因存在三种表示就强行合并。真正的问题是市场、订单和成交语义仍在 legacy `.core` 与 canonical `.venue` 路径重复维护，并同时更新兼容标量与 OMS 投影。

**持久化没接到核心。** `journal.zig` 是 16KiB 内存段 + CRC32C，所有 `applyStable` 都走它。`durable_store.zig` 有 Linux 文件实现，但没有任何 `TradingShard` 调用方。断电恢复资格按 ADR 自己也没宣称完成。

**策略运行时未一等公民。** Zig timer 路径永远挂一张硬编码限价买单。Python `strategy_host.py` 写明交易逻辑尚未到达。HostSupervisor 只在测试里拉起，引擎进程并不拥有它。

结论：作为 Zig 确定性交易内核，架构方向对；作为多进程、多交易所生产系统，文档超前于接线。

---

## 2. 安全与漏洞

当前分支**没有**“未认证远程直接打实盘资金”的路径：执行凭证准入明确拒绝，生产进程链只声称 `SimulatedVenue`。下面是已经写进代码、将来接上执行凭证就会变成高危的问题。

### 高

**H1. StrategyHost 隔离是约定，不是强制。**
CONTEXT 要求 Python 拿不到共享内存指针/原子游标，Host 故障不得阻塞核心。实现里 Linux `memfd_create` 无 seal、无 `CLOEXEC`，fd 号走 argv，子进程把 input/output 都 mmap 成读写。恶意或崩溃的 Python 可以改游标、`ftruncate` 触发 SIGBUS、写引擎的 input ring。C ABI 校验只在 Python 走 `qsh_*` 时生效。这不会单独绕过风控下单，但违反隔离与可用性。

**H2. `risk.assess` 与 OMS 仍有未检查算术。**
`risk.zig` 的 `quantity * price_ticks`、`notional * ppm`、buffer/distance 乘法，以及 OMS 的 `cumulative + remaining` 和 amend 数量加法仍使用裸运算。当前生产合同固定 `ReleaseSafe`，极值输入通常先触发 trap/进程失败，直接风险是拒绝服务；只有改用 `ReleaseFast` 或关闭运行时安全时，才可能静默回绕并少占保证金。修复必须覆盖共享算术 helper 与 OMS 数量验证，不能只替换两处乘法。

### 中

**M1. HostActivated 尚未成为分片权威事实。** `strategy_host_gateway` 初次构造仍默认 `trading_enabled = true`，Python 的直接 `trade` 模式也不等待 `ACTIVATE_STRATEGY`；但 recovery 路径现在会等待并验证激活帧、摘要与 barrier。因此不是所有 Host 路径都缺少激活检查。真正缺口是 HostActivated/activation barrier 没有进入 `TradingShard.apply` 的权威日志并驱动 Gateway 投影，控制通道与数据面仍可各自开门。

**M2. 生产 role 控制 socket 没有语义认证。** systemd 写死 `--generation 1` 且 `Restart=on-failure`，重启不递增 generation。`enable_risk` 是一字节 `'A'`，无 `SO_PEERCRED`、无签名，首个获准访问 socket 的连接会被接受。独立 UID、`RuntimeDirectoryMode` 与 UMask 缩小了本机攻击面，且当前 role 只控制 `SimulatedVenue` 生命周期；但真实模块接线前必须绑定明确 controller 身份和单调持久 generation。

**M3. NodeFence / PrimaryLease 没接到发送。** `failover.zig` 的围栏是进程内布尔 + 本地 `authority.bin`。`GatewayLeaseGuard` 不被 `execution_gateway.send` 调用。两台机器两份文件就是脑裂，除非外部真把旧节点网络切断——代码里没有。

**M4. ControlCommand 未验签。** `content_hash` 只检查非零。能注入 `CoreEvent.control_command` 就能 `enable_trading`。CONTEXT 的软件签名/VPN/TOTP 不存在。`src/` 里没有名为 KillSwitch 的命令。

**M5. 执行网关不复核风控/授权/fencing。** 只查 latch、品种缺口、能力版本。公开 `send()` 接受原始 `OrderCommand`。OKX Demo 有时直接 `adapter.trySend`，绕过 Gateway。

**M6. Demo 凭证仍走环境变量。** `RINGWIN_OKX_*` 与生产 CredentialStore 的“禁止 argv/env 密码”是两套明确隔离的模型。`okx_rest_auth.Credentials` 是会清零的固定容量结构，并非 CredentialStore 的 `mlock`/`DONTDUMP` 受保护页；请求头仍包含 API key 与 passphrase。当前影响是同机环境或进程转储泄露独立 Demo 凭证，不是生产执行凭证风险，且强制 Demo header 阻止静默切到实盘。

**M7. CredentialStore TTY 读口令未关回显。** 解锁口令可能出现在控制台。

### 设计上 fail-closed、不要当成漏洞

- `admitExecution` 固定返回 `ExecutionAdmissionOutOfScope`（ADR 0005）。
- 观察凭证解锁后立即 `lease.deinit()`，Ready 不含明文。
- OKX 头写死 `x-simulated-trading: 1`，不能静默打实盘。
- Replay 路径断言无发送能力。
- 未知 dispatch / 未解决对账会 latch 账户。
- 品种 gate 表满则全部视为 gap。
- 定点账本多数走 `std.math.add/mul` 并做闭合断言；这只是总体风格，不能视为所有风险/经济路径已具备溢出失败关闭证明。

---

## 3. 业务逻辑：完善度与具体错误

核心切片（OMS + `risk.assess` + `economics.Projection` + `operational.State` + `AccountCoordinator`）在**玩具容量**下是闭合的：最多 8 张单、4 个品种、单 VirtualPortfolio、IsolatedLinear / spot。

已实现：place / 原生 amend / cancel、IntentGroup、Unknown 阻塞新发、ConfirmedAbsent 的**核心事件**路径、五层限额、开仓/预警/强平三档、DeRisk / Pause / KeepPositions、均价成本、手续费不进成本、账户级毛保证金不把净额抵消当购买力。

### 必须修的逻辑错误

1. **`ConfirmedAbsent` 可以变成 filled。** `oms.zig` 把 `found_terminal` 和 `confirmed_absent` 同一分支：剩余量为 0 且累计等于订单量就标 filled 并保留 reservation。领域定义：ConfirmedAbsent 证明 Unknown 提交**没有**形成 Venue Order。

2. **规范对账到不了 OMS。** `handleCanonical` 对 `order_reconciliation_result` 只在 `unresolved` 时 latch，不调用 `oms.applyReconciliation`。真实 Venue 事实无法关闭 Unknown / 完成 Cancel-Confirm-Create。CCC 只接在核心 `oms_reconciliation_result` 上。

3. **Reduce-only 被推断后当网关放行条件。** `risk.Request` 只有组合 reduce-only；Venue 侧总是推断。`qualifyOmsGroup` 覆盖两个标志。Gateway 用 `portfolio_reduce_only OR venue_reduce_only` 判定“不增风险”，latched 账户仍可能发出对账户净仓增风险的单。

4. **部分成交不释放 OMS reservation。** 报告更新累计数量，占用仍是下单全额。Canonical fill 不调用 `refreshLayeredReservations`。协调器毛保证金偏高。

5. **两套风控账本。** `qualifyOmsGroup` 用 MarginRules ppm；`recalculateRisk` 仍用写死的 50x 杠杆和遗留单订单字段。多单后 `RiskLeaseDoesNotClose` 对的是错误不变量。

6. **强平距离 0 被改成无穷。** `account_coordinator.zig` 把 `ticks == 0` 写成 `maxInt(i64)`。领域：0 表示已到强平；Unknown 只用于输入不全。

7. **无主强平成交派给 `shard_0`。** 协调器注释写 Suspense，代码 `owner orelse .shard_0`。若 shard_0 有同向仓，会记到该组合而不是暂记。

8. **IsolatedLinear + cash 被改成 spot。** `trading_shard.zig` 静默改产品类型。领域禁止用兼容字段混模型。

9. **L2 缺数量填 1。** 静默补市场数据。

10. **Canonical fill 缺 fee 当 0。**

11. **Host 拒绝原因撒谎。** 未授权记成 `market_data_gap`；限额/开仓门拒绝记成 `global_risk_lease_exceeded`。

12. **CCC 替换绕过 `blocksNewSend`。** 另一张单仍 Unknown 时可能发新单。

13. **Timer 策略 `intent_sequence` 恒为 1，client id 恒为 `RWN-00000001-01-000000000001`。** 不能当真实策略路径。

14. **OMS 不按 `OrderIntentIdentity` 幂等。** 重放同一 IntentGroup 会再开一张单。Host 网关有 seen 表，OMS 没有。

15. **Python/Host 路径拒卖、拒 reduce-only。** 只允许买单限价。生命周期命令里的减仓走不了这条路。

### 领域一等公民但核心没有的

KillSwitch 命令、OrderNormalization / CapabilityDegradation、发送时复核 post-only / 价格保护、多策略同 DecisionDomain、资金费按仓位加权分配、强制成交按贡献归属、HostActivated 屏障和跨 VP 的 OpeningBalance 约束尚未成为 `apply` 不变量。DispatchDeadline 已存在于 Canonical OrderCommand 且 Venue adapter 会在传输前检查；其剩余缺口是没有由 OMS 拥有，也没有成为分片日志中的权威调度语义。

容量：`oms.max_orders = 8` 且不淘汰已完成订单；`instrument_registry.max_entries = 4`；gateway 品种门 4 个。第八张历史单之后直接 `OrderCapacityExceeded`。

---

## 4. 重叠功能与重复代码

| 重叠 | 位置 | 风险 |
|---|---|---|
| 四套 OrderCommand | `canonical_event` / `oms.Command` / `trading_shard.OrderCommand` / `okx_order_entry.OrderCommand` | 边界类型不必全部合并；应删除 legacy compatibility 命令，并补齐 OMS→Gateway 丢失的 post-only/TIF/保护价 |
| 遗留单订单机 + OMS | `TradingShard.order_state` 与 `oms.Oms` | 状态分叉 |
| 核心行情路径 + canonical 行情路径 | `handle` vs `handleCanonical` | digest 偏移 |
| Binance ≈ Bybit 适配器 | 生命周期、限流、unknown latch、名义上限几乎复制 | 已开始漂移（错误码、frame 上限） |
| 多份 RawSink/Times | OKX / Binance public / Binance order raw / Bybit feed / Bybit private | Bybit feed 缺 `max_raw_frame_bytes` |
| 资格模块 | `binance_testnet_acceptance` 与 `bybit_testnet_acceptance` 同构 | 代码很小且类型隔离是安全属性；暂不抽框架，最多复用稳定的纯校验 helper |
| 凭证 | CredentialStore vs `RINGWIN_OKX_*` env vs `okx_rest_auth.Credentials` | 生产模型与 Demo 模型并存 |
| 事件词汇 | Canonical / Core / Host IPC | 编码分层合理；风险来自重复业务语义和字段丢失，不来自表示数量本身 |
| `okx_spot_projection.zig` | 未被 `main.zig` 测试图引用 | 第二套成交账本 |

OKX 是唯一有真实传输的栈（`okx_order_entry` → `okx_live_chain` → libcurl）。Binance/Bybit 的 `native_amend` / `native_post_only` 当前只有适配器单测和 JSON 夹具，在线资格仍为 `not_run`；Binance spot 编码把 `operation: amend` 放入通用 body，也不符合真实 API。`production_candidate` 表示允许未来取得资格的目标范围，并不宣称已经合格；真正的问题是同一矩阵把 required capabilities 与 verified evidence 混在一起，容易误读。

不要做通用 REST 插件或 acceptance 框架（ADR 0001 已否决）。优先用共享合同锁住行为；只有第三个稳定重复或已证明漂移时，才提取最小 RawIngress/纯校验 helper。不要把 OKX、Binance、Bybit 的协议和认证细节抽成共同所有者。

---

## 5. 建议优先级

### P0：先修权威状态与资金安全不变量

1. **修对账与 ConfirmedAbsent。** Venue `order_reconciliation_result` 必须携带足够的 Order/数量/版本证据并推进 OMS；ConfirmedAbsent 只能证明未形成 Venue Order，不得变成 filled。
2. **Reduce-only 按账户净仓强制。** 唯一发送边界必须基于带版本和 barrier 的 ExchangePosition、方向与数量复核真实减仓；不能信任两个调用方布尔值的 OR。
3. **checked 算术覆盖共享 helper。** 收口 `notionalAtoms`、`rateAtoms`、buffer/distance、ceil 与 OMS 报告/amend 数量，极值输入返回稳定错误；生产继续固定 ReleaseSafe。
4. **修正危险事实解释。** liquidation distance 的 0 保持为已到阈值；未归属强制成交进入真正的 SuspenseAccount/ReconciliationBreak；缺 fee、缺 L2 数量不得猜成 0 或 1。
5. **让 OMS 成为 OrderIntentIdentity 的幂等所有者。** 重复为 no-op，冲突锁存；CCC 创建替代单前重新执行全局 Unknown/PendingCancel 阻断。

### P1：收口唯一运行链

6. **删除竞争状态，而不是合并全部边界类型。** 以 expand-contract 迁移快照、摘要、fixture 和调用方，最终删除 `order_state`、兼容 OrderCommand、硬编码 timer 买单和 50x `recalculateRisk`；CoreEvent 的控制/运营/内部事实继续保留。
7. **`sendOms` 成为唯一业务订单发送边界。** OMS Command 携带最终 order type、TIF、保护价、RiskReservation 和授权证据；Gateway 在最后时刻复核 EffectiveTradingAuthority、deadline、PrimaryLease/FencingToken 和能力版本。Adapter 合同测试与对账请求仍可直接调用 seam。
8. **把 DurableStore 接到 engine 事务协调层。** TradingShard 继续做纯语义验证；engine 在外部发送前完成日志 append/commit barrier，并在持久化失败时进入 RecoveryOnly。不要把 Linux 文件 IO 塞入 TradingShard。
9. **把生产 role 接到真实所有者。** engine 拥有分片与持久化协调，market-feed/execution-gateway 拥有适配器，control-fence 接收既有 Web 控制面验证过的签名 ControlCommand。五 role 是 ADR 0003 的已接受方向；若要删除必须先 supersede ADR，不新增控制面 CLI。
10. **让 HostActivated 成为权威分片事实并强制 IPC 权限。** Gateway 默认关闭交易，持久化 HostActivated 后才开放；Python 只通过 Zig bridge 获得 bytes。`SCM_RIGHTS` 本身不提供隔离，还需防伸缩 seal、只读 input fd/mapping、可写 output 及关闭多余 fd。
11. **补齐本机控制与凭证卫生。** role socket 校验 controller UID/peer credential 和签名事实，generation 来自单调持久状态；生产优先通过受限 fd 提供口令，保留 TTY 时必须关闭并恢复回显；Demo 凭证继续与生产 execution admission 隔离并移出环境变量。

### P2：资格证据与长期容量

12. **拆分目标能力与验证证据。** 保留 `production_candidate` 作为目标范围，把 required capability、当前 verified capability、资格环境和证据引用分开；Binance/Bybit 在真实 transport/testnet 完成前保持 `not_run`。
13. **实现确定性容量管理。** 终态订单使用可重放墓碑/归档，保留幂等、对账和 predecessor 证据；容量不足明确进入 RecoveryOnly。按目标账户、Instrument 和长期订单量做资格，不用简单删除数组元素掩盖上限。

---

## 6. 一句话

`main` 上的 RingWin 是高质量的**离线确定性内核 + OKX Demo 垂直链 + 若干尚未接线的生产 seam**。安全姿态整体 fail-closed；当前最优先的是修复对账/ConfirmedAbsent/reduce-only、极值算术、危险事实解释与 OMS 幂等，再收口唯一发送、竞争状态、持久化和 Host/生产 role 接线。它目前不适合实盘资金，且通过现有 214 项回归不等于这些生产不变量已经闭合。
