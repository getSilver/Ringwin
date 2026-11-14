# RingWin `main` 代码审查

范围：本机 `D:\github\Ringwin` 的已提交 `main`，HEAD `93a4ccd`（比 `origin/main` 超前 29 个提交）。未读工作区任务，未把未提交改动算进结论。

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

**两套事件语言。** `canonical_event.zig` 是适配器事实；`trading_shard_event.zig` 是分片日志事实。Python Host 还有第三套 `strategy_host_gateway.EventType`。市场/成交在 `.core` 和 `.venue` 两条臂上各写一遍。

**持久化没接到核心。** `journal.zig` 是 16KiB 内存段 + CRC32C，所有 `applyStable` 都走它。`durable_store.zig` 有 Linux 文件实现，但没有任何 `TradingShard` 调用方。断电恢复资格按 ADR 自己也没宣称完成。

**策略运行时未一等公民。** Zig timer 路径永远挂一张硬编码限价买单。Python `strategy_host.py` 写明交易逻辑尚未到达。HostSupervisor 只在测试里拉起，引擎进程并不拥有它。

结论：作为 Zig 确定性交易内核，架构方向对；作为多进程、多交易所生产系统，文档超前于接线。

---

## 2. 安全与漏洞

当前分支**没有**“未认证远程直接打实盘资金”的路径：执行凭证准入明确拒绝，生产进程链只声称 `SimulatedVenue`。下面是已经写进代码、将来接上执行凭证就会变成高危的问题。

### 高

**H1. StrategyHost 隔离是约定，不是强制。**  
CONTEXT 要求 Python 拿不到共享内存指针/原子游标，Host 故障不得阻塞核心。实现里 Linux `memfd_create` 无 seal、无 `CLOEXEC`，fd 号走 argv，子进程把 input/output 都 mmap 成读写。恶意或崩溃的 Python 可以改游标、`ftruncate` 触发 SIGBUS、写引擎的 input ring。C ABI 校验只在 Python 走 `qsh_*` 时生效。这不会单独绕过风控下单，但违反隔离与可用性。

**H2. `risk.assess` 与 OMS 数量用包装算术。**  
`risk.zig` 的 `quantity * price_ticks`、`notional * ppm` 是裸 `i128` 乘法，溢出回绕。Host 路径先用会失败的 `i64` 名义检查兜住；`oms_intent_group` 直进 `qualifyOmsGroup`，没有这层。OMS 里 `cumulative + remaining` 也是包装 `i64`。回绕成小正数会**少占保证金**。

### 中

**M1. HostActivated 没落在数据面。** `strategy_host_gateway` 默认 `trading_enabled = true`。Python 进程启动就带 `--activation-identity`，一批行情来了就 `trade_once()`，不等 `ACTIVATE_STRATEGY`。Supervisor 的 `validatesEnvelope` 只在测试里用。

**M2. 生产控制面没有认证。** systemd 写死 `--generation 1` 且 `Restart=on-failure`，重启不递增 generation。`enable_risk` 是一字节 `'A'`，无 `SO_PEERCRED`、无签名。先连上的进程获胜。unit 的 UMask/用户隔离是真的，语义安全模型不在这个进程上。

**M3. NodeFence / PrimaryLease 没接到发送。** `failover.zig` 的围栏是进程内布尔 + 本地 `authority.bin`。`GatewayLeaseGuard` 不被 `execution_gateway.send` 调用。两台机器两份文件就是脑裂，除非外部真把旧节点网络切断——代码里没有。

**M4. ControlCommand 未验签。** `content_hash` 只检查非零。能注入 `CoreEvent.control_command` 就能 `enable_trading`。CONTEXT 的软件签名/VPN/TOTP 不存在。`src/` 里没有名为 KillSwitch 的命令。

**M5. 执行网关不复核风控/授权/fencing。** 只查 latch、品种缺口、能力版本。公开 `send()` 接受原始 `OrderCommand`。OKX Demo 有时直接 `adapter.trySend`，绕过 Gateway。

**M6. Demo 凭证走环境变量。** `RINGWIN_OKX_*` 与 CredentialStore“禁止 argv/env 密码”并列存在。`okx_rest_auth` 密钥在普通堆内存，请求头带 API key 和 passphrase。

**M7. CredentialStore TTY 读口令未关回显。** 解锁口令可能出现在控制台。

### 设计上 fail-closed、不要当成漏洞

- `admitExecution` 固定返回 `ExecutionAdmissionOutOfScope`（ADR 0005）。
- 观察凭证解锁后立即 `lease.deinit()`，Ready 不含明文。
- OKX 头写死 `x-simulated-trading: 1`，不能静默打实盘。
- Replay 路径断言无发送能力。
- 未知 dispatch / 未解决对账会 latch 账户。
- 品种 gate 表满则全部视为 gap。
- 定点账本多数走 `std.math.add/mul` 并做闭合断言。

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

KillSwitch 命令、OrderNormalization / CapabilityDegradation、发送时复核 post-only / 价格保护、多策略同 DecisionDomain、资金费按仓位加权分配、强制成交按贡献归属、HostActivated 屏障、DispatchDeadline 的真实语义、跨 VP 的 OpeningBalance 约束。这些写在 `CONTEXT.md`，没有成为 `apply` 不变量。

容量：`oms.max_orders = 8` 且不淘汰已完成订单；`instrument_registry.max_entries = 4`；gateway 品种门 4 个。第八张历史单之后直接 `OrderCapacityExceeded`。

---

## 4. 重叠功能与重复代码

| 重叠 | 位置 | 风险 |
|---|---|---|
| 四套 OrderCommand | `canonical_event` / `oms.Command` / `trading_shard.OrderCommand` / `okx_order_entry.OrderCommand` | 字段丢失（post-only/TIF 在 OMS→Gateway 默认成 limit+GTC） |
| 遗留单订单机 + OMS | `TradingShard.order_state` 与 `oms.Oms` | 状态分叉 |
| 核心行情路径 + canonical 行情路径 | `handle` vs `handleCanonical` | digest 偏移 |
| Binance ≈ Bybit 适配器 | 生命周期、限流、unknown latch、名义上限几乎复制 | 已开始漂移（错误码、frame 上限） |
| 多份 RawSink/Times | OKX / Binance public / Binance order raw / Bybit feed / Bybit private | Bybit feed 缺 `max_raw_frame_bytes` |
| 资格模块 | `binance_testnet_acceptance` 与 `bybit_testnet_acceptance` 同构 | 可抽实现，类型必须分开 |
| 凭证 | CredentialStore vs `RINGWIN_OKX_*` env vs `okx_rest_auth.Credentials` | 生产模型与 Demo 模型并存 |
| 事件词汇 | Canonical / Core / Host IPC | 翻译层膨胀 |
| `okx_spot_projection.zig` | 未被 `main.zig` 测试图引用 | 第二套成交账本 |

OKX 是唯一有真实传输的栈（`okx_order_entry` → `okx_live_chain` → libcurl）。Binance/Bybit 的 `native_amend` / `native_post_only` 是适配器单测和 JSON 夹具，`production_contract` 却把它们标成 `production_candidate`。Binance spot 编码走 `operation: amend`，对不上 Binance 真实 API。

不要做通用 REST 插件框架（ADR 0001 已否决）。该抽的是 RawIngress 和 Binance/Bybit 的 session/unknown 壳，不要抽 OKX。

---

## 5. 建议优先级

1. **删掉双状态，而不是再拆文件。** 冻结/删除 `order_state`、硬编码 timer 买单、`recalculateRisk` 的 50x 路径。只留 OMS + `handleCanonical` + `risk.assess`。
2. **修对账与 ConfirmedAbsent。** Venue `order_reconciliation_result` 必须推进 OMS；Absent 不得变 filled。
3. **Reduce-only 按账户净仓强制。** Gateway 在 latch 时只放行真正降低 **ExchangePosition** 的单；不要用组合 OR。
4. **checked 算术**进 `risk.assess` 和 OMS 数量。
5. **Host 隔离落到机制：** memfd seal、子进程 input 只读、SCM_RIGHTS 传 fd、默认 `trading_enabled = false`、ingest 前走 HostActivated。
6. **`sendOms` 成为唯一发送。** 带上 order_type/TIF、EnableTrading、fencing、RiskReservation。Demo 也不要直打 adapter。
7. **DurableStore 接到 `applyStable`。** 现在 `--durable-store-test` 不能当引擎恢复证据。
8. **生产角色要么调真实模块，要么不要假装五进程。** engine 拥有分片+journal；market-feed/execution-gateway 拥有适配器；control-fence 应用已签名 ControlCommand。
9. **能力矩阵诚实。** 未接真实 REST 的 Binance/Bybit 行不要标 `native_amend` / production_candidate。
10. **容量与淘汰。** 8 张单、4 品种撑不住实盘；至少要有终态订单压缩或明确的 RecoveryOnly。

---

## 6. 一句话

`main` 上的 RingWin 是高质量的**离线确定性内核 + OKX Demo 垂直链 + 若干尚未接线的生产缝**。安全姿态整体 fail-closed，真正的漏洞集中在：隔离可被 Python 打破、风控乘法回绕、对账/ConfirmedAbsent/reduce-only 不变量、以及文档中的生产拓扑尚未存在。不适合实盘资金；继续做的最大杠杆是合并双状态机、把 Venue 对账接到 OMS、再接线持久化与唯一发送路径。
