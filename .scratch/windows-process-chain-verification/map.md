# Windows OKX 业务进程链验证

Status: active

## Destination

在 Windows 上只用 OKX VenueAdapter 与 OKX MarketFeedAdapter 验证一个冻结范围内的业务闭环：
OKX 行情及私有事实 → CanonicalEvent → StrategyHost/TradingShard → 风控/OMS → 独立
ExecutionGateway → 发送前 DurableStore commit → OKX Demo → 回报、成交、费用及账户事实 →
权威状态、对账、重启恢复。先用可注入 transport 离线证明，再做在线只读预检；只有另获当次
SystemOwner 明确授权，才执行有界 Demo 写入与清理。结果只适用于被测账户、产品、策略、
配置和源码版本，不代表项目所有功能正确或具备生产资格。

## Definition of done

- 修订 [ADR 0008](../../docs/adr/0008-windows-verification-runtime.md)、CONTEXT 与验证合同，
  解除其“本波只接 SimulatedVenue、OKX Demo 独立运行”的旧范围；Windows 仍非
  ProductionPlatform，`permitsProduction()` 保持 false。
- 五个 VerificationRole 的真实所有权与跨进程消息路径可追踪。engine 持有 TradingShard、
  HostSupervisor 与权威决策状态；execution-gateway role 持有唯一 Gateway、
  OKX VenueAdapter 与 Demo transport；market-feed role 持有 OKX MarketFeedAdapter。
  行情、意图、命令、私有回报和控制事实经有界、身份与 generation 校验的 IPC 传递。
  telemetry/control-fence 具有实际职责与失败关闭条件。进程内 Gateway、空 role 不能算通过。
- 同一条链完成 Recovering → Ready → Trading → Draining：真实 Host 握手、恢复、完成
  HostActivated 屏障并产生最小确定性策略意图；Gateway 发送时复核权限、能力、
  DispatchDeadline、lease/fencing 和账户范围。权威输入、DispatchProof、私有结果及
  snapshot/replay 经 DurableStore；提交失败、Unknown、断线或缺 role 时撤销新增风险，
  不自动重发。
- 离线验收使用 OKX Adapter 的假 transport、公共/私有原始帧和故障注入，覆盖拒绝、接单、
  部分/全部成交、取消、report/Fill 重复与逆序、费用、对账、崩溃恢复、唯一经济记账、
  账本与账户一致，以及 replay 无发送能力。SimulatedVenue 不能代替这项验收。
- OKX Demo 凭证由仓库根目录被忽略的 `.env.local` 经现有 PowerShell 装载入口提供，
  仅传入限定 Demo 子进程；日志、argv、快照、报告及 tracker 不含凭证明文。
  校验 Demo endpoint、账户和权限。Windows CredentialStore 的只读适配器验收不冒充
  OKX execution credential admission，`.env.local` 存在也不授予下单权限。
- 在线只读预检证明 OKX Demo REST、公共/私有 WS、规则、余额、持仓和挂单基线。
  当次另获授权的有界写验收须证明至少一笔订单经本进程链到 OKX Demo 并取得真实终态与
  经济 Fill，随后受限清理；最终权威对账确认无 Unknown、挂单、负债、仓位或测试资产敞口。
  未闭合结果保持失败或待处理，不输出 passed。
- `zig build` 提供明确的离线、Windows adapter 和 Windows OKX 业务链入口；报告绑定源码
  revision、账户/产品/配置、schema、运行模式和脱敏证据。离线、只读、授权 Demo 写入
  分别记录；README、ADR、CONTEXT 与资格输出使用当前源码版本，不硬编码历史测试数。

## Rules

- 不取代 [ADR 0002](../../docs/adr/0002-linux-production-support-contract.md) 或
  [ADR 0003](../../docs/adr/0003-linux-production-process-chain.md)；Windows 证据不关闭
  [Linux 生产资格收口](../production-readiness/map.md) 的票 02–11。
- 本波业务链只使用 OKX Adapter。Binance/Bybit Adapter 的实现、修复、活链及资格排除；
  历史票 02 的已完成代码不构成本波资格，Testnet 保持 `not_run`。
- OKX 私有事件翻译留在 VenueAdapter：`ingestPrivateWs -> tryDrain -> applyAdapterBatch ->
  TradingShard -> DurableStore -> snapshot/replay`；核心和验证控制器不翻译 OKX 私有字段。
- 若离线或只读验收发现 OKX VenueAdapter 尚不能正确编码订单、翻译私有事实或完成对账，
  先在票 05 内完善该 Adapter，并通过对应回归后再进入 Demo 下单验收；不得用验证控制器
  绕过 Adapter 缺口。
- `.env.local` 是 Demo 凭证输入，不是订单授权。不得读取或记录其明文作证据。每次 Demo
  写入及清理仍需当次、限定账户/产品/数量/名义/时间的 SystemOwner 明确授权；
  本图修订不授权真实下单。
- 每次只认领 Frontier 一张票；保持现有 Web 控制面为人工操作面，不新增控制面 CLI。
  历史 resolved 票保留原始证据，重开票按当前源码验收；不同步 GitHub Issues。

## Route

1. [修订 Windows 验证合同与词汇](issues/01-freeze-windows-verification-contract.md) — resolved；05 使用新合同。
2. [Windows DurableStore 验证适配器](issues/03-add-windows-durable-store-adapter.md) — resolved；05 复用其 seam。
3. [Windows CredentialStore 只读适配器](issues/04-add-windows-credential-store-adapter.md) — resolved；不代替 Demo 执行凭证。
4. [接通 Windows OKX 业务进程链](issues/05-wire-windows-verification-process-chain.md) — resolved；五进程 Demo 买卖及零敞口闭环通过。
5. [封存 Windows OKX 业务证据与文档](issues/06-seal-windows-process-chain-verified.md) — in-progress；需绑定最终源码并输出资格报告。

## Frontier

- [06 封存 Windows OKX 业务证据与文档](issues/06-seal-windows-process-chain-verified.md)。

## Decisions so far

- 2026-09-29：[05 Demo 买卖闭环证据](evidence-2026-09-29-demo-round-trip.json)记录同链
  BTC-USDT 买单 `3965154311785299968`、卖单 `3965155877300879360` 均真实
  `filled`；私有 report、Fill、费用与账户事实进入 engine，磁盘重开恢复与独立 REST
  复核均为零敞口。05 resolved；06 继续封存精确源码与机器资格报告，
  `windows_process_chain_verified` 当前仍 blocked，生产资格 false。OKX 已成交历史
  不能通过取消挂单接口删除，旧终态记录按 Adapter 对账语义处理。
- 2026-09-29：05 已发出并核对三笔真实 Demo 买单，失败期间的 BTC 残余均以受限应急
  卖单清至零；应急卖单没有经过五进程 Gateway，不能作为同链减仓证据。详见
  [05 进度](issues/05-wire-windows-verification-process-chain.md)。05 继续 `in-progress`，
  06 继续 blocked；停止重复买入直到发送时效、账户观察与私有恢复回归审清。
- 2026-09-28：[离线重放证据](evidence-2026-09-28-offline-replay.json)显示公共行情
  RawIngress 的磁盘重开回归可在 OKX MarketFeedAdapter 内无写重放，
  错误 session/摘要失败关闭。仍是单进程离线证据，不改变 05/06 状态。
- 2026-09-27：用户当次明确授权当前 OKX Demo 账户执行 05 所需写入与清理；执行范围
  自限 BTC-USDT、每单至多 25 USDT，实际启动时固定截止时间并绑定只读预检的账户
  UID SHA-256。当前只读预检通过、订单写入为零；Windows 独立 OKX 执行链尚未接通，
  因此尚未使用授权，也未改变 05/06 状态。
- 2026-09-27：05 新增[离线磁盘续证据](evidence-2026-09-27-offline-disk-followup.json)：
  OKX 原始帧、DispatchProof 与 Owner 私有成交路径经 WindowsFileAdapter 提交，关闭重开
  后核对 raw 摘要、终态、经济 Fill 与 digest。此项仍是单进程假 transport；五进程 OKX
  业务路由和当次授权 Demo 成交未完成，05 继续 `in-progress`，06 继续 blocked。
- 2026-09-27：票 05 的[当次离线与只读证据](evidence-2026-09-27-offline-readonly.json)
  已绑定相关源码 SHA-256；OKX Demo 公共/私有 WS 与 REST 基线通过，但账户身份、
  跨进程 OKX 业务消息、权威磁盘恢复及真实成交仍缺证据，资格继续 `blocked`。
- 2026-09-27：票 05 已开始。历史 `windows-chain` 的拒绝事实及回放修复后可运行，
  但只输出 `blocked`；OKX Adapter 定向测试 60/60、行情 Adapter 15/15，Demo REST 与
  私有 WS 只读准备通过。真实跨进程 Gateway 所有权和 OKX 下单链仍未建立。
- 2026-09-27：票 01 完成合同修订。旧 SimulatedVenue 结果不再授予 Windows OKX 业务资格；
  `WindowsChainEvidence` 要求三种模式及 role、恢复、最终对账均通过。定向测试 7/7、9/9；
  当前 `windows-chain` 仍因 `HostIntentBeforeActivation` 失败，完整主测试在 82/297 栈溢出。
- 2026-09-27：用户将目标改为 Windows 上只用 OKX Adapter 验证端到端业务正确性；
  Demo 凭证位于 `.env.local`。本次只修订地图和现有票，不读取凭证明文、不执行在线写入。
- 2026-09-27：当前 `zig build windows-chain` 在 engine 初始化因误判激活前 Host 拒绝事实而失败。
  即使修复，Gateway/SimulatedVenue 仍在 engine 内，HostSupervisor 仅初始化，不能证明新目标；
  2026-09-18 记录的 `passed` 不再作为当前有效结论。
- 2026-09-27：现有 OKX Demo runner 写入业务入口是 Linux-only，Windows 仅能
  `prepare_only`；Windows 进程链目前只接 SimulatedVenue。Windows OKX 接线与恢复尚未验收。
- 2026-09-18：原 01–06 曾按 SimulatedVenue 范围标为 resolved；独立的
  `zig build windows-durable`、`zig build windows-credential` 仍是适配器级证据。
- 2026-09-17：Windows 是验证运行时而非 ProductionPlatform；Linux 生产合同与
  `permitsProduction()` 不变。Binance/Bybit 在线资格保持 `not_run`。

## Not yet specified

- 在线写验收的具体 OKX Demo 账户、产品、最大数量/名义、截止时间和授权轮次由当次
  SystemOwner 在执行前给出；地图本身不授权下单或自动清理。
- `.env.local` 的实际权限与账户范围只能在只读预检中核对，不能从文件存在性推断。
- Web 控制面到 Windows 节点、独立 NodeFence、双机 HA 和真实遥测 exporter 若要验收，
  另按对应地图定义；本图业务正确性结论不覆盖这些能力。

## Out of scope

- Binance/Bybit Adapter 与 Testnet；SimulatedVenue 作为本波业务链替身。
- Windows `production_qualified`、Linux 在线/断电/soak/生产账户与 Canary。
- 未冻结的 Venue、产品、账户、策略组合，以及项目所有功能的无条件正确性宣称。
- 第二套控制面 CLI、通用 REST 插件框架和无证据的自动订单重发。
