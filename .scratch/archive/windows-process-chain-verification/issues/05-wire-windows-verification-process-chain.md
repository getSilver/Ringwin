# 接通 Windows OKX 业务进程链

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [Windows OKX 业务进程链验证](../map.md)

## Question

如何让 Windows 五个 VerificationRole 通过唯一 OKX Adapter 跑通行情、策略、风控、
OMS、发送、私有成交、账本、对账与恢复，而不是只启动进程或在 engine 内运行模拟 Gateway？

## What to build

先纠正当前 `zig build windows-chain` 的 Host 拒绝事实误判；ready 只能在 owner 初始化和
必要握手完成后报告。按 01 冻结的范围接通真实 role 所有权：
market-feed 持有 OKX MarketFeedAdapter，engine 持有 TradingShard、决策 DurableStore、
HostSupervisor 和最小确定性真实 StrategyHost，execution-gateway 持有唯一 Gateway、
OKX VenueAdapter 与 Demo transport。telemetry/control-fence 只承担其明确职责。
控制、行情、意图、命令与私有事实跨 role 经有界 Named Pipe，SID、generation、非法帧、
背压、断线和 role 缺失均失败关闭。

离线阶段使用 OKX Adapter 可注入 transport 和脱敏原始帧；私有翻译只在 Adapter。
权威事件先持久化，发送前提交 DispatchProof；接单、部分/全部成交、费用、余额、持仓、
重放与恢复通过实际 Owner/TradingShard 路径，不手工重建同组 fixture 冒充磁盘恢复。
测试 commit 失败、Unknown、崩溃边界、过期 deadline、旧 generation、Host 未激活、
控制台关闭与重启；重放不能发送，Unknown 只能经权威对账解除。
若上述验证暴露 OKX VenueAdapter 的订单编码、私有事实翻译或对账缺口，先在
VenueAdapter 边界修复并重跑对应离线回归，再进入在线下单阶段。

在线阶段复用已有 `.env.local` PowerShell 装载入口，只在限定 Demo 子进程提供必要
凭证和固定 Demo endpoint；不得把 CredentialStore 只读验收等同执行准入。
先做只读预检。真实 Demo 写入、清理或再次尝试必须另获当次限定账户、产品、
数量/名义与时间的 SystemOwner 明确授权；地图或离线通过均不授权。写入后由
OKX 私有 WS 与 REST 权威事实共同确认终态、经济 Fill、费用及零残余敞口；
遇 Unknown、残余或用户停止清理指令时停止新增写入并保留失败证据。

## Acceptance criteria

- [x] `zig build windows-chain` 在当前源码通过；Host 激活前意图按实际拒绝事实断言，
      ready 不早于 owner/握手完成。
- [x] 五 role 的业务消息确实跨进程，Gateway/OKX Adapter 只由 execution-gateway role
      持有；不以 engine 进程内 Gateway 或 SimulatedVenue 作为通过路径。
- [x] 真实 Host 经 Zig 校验 pipe、HostActivated 屏障产生 OrderIntent，再经风控、
      OMS、Gateway、OKX Adapter；行情由 OKX MarketFeedAdapter 输入。
- [x] OKX `ingestPrivateWs -> tryDrain -> applyAdapterBatch` 覆盖 report/Fill 顺序、
      重复、部分成交、费用与账户对账；权威账本和经济敞口一致。
- [x] 下单前确认 OKX VenueAdapter 的目标订单编码、私有事实翻译与对账回归通过；
      发现缺口时先修复 Adapter，不能由 Demo runner 自行翻译或绕过。
- [x] DurableStore 故障不发送；真实磁盘恢复重放权威输入、dispatch 和私有事实，
      digest 等价且 `replay_send_capability=false`，不自动重发 Unknown。
- [x] SID、generation、非法帧、背压、断线、缺 role、deadline、lease/fencing、
      Host 未激活与控制台关闭的失败关闭路径由可运行验收检查。
- [x] 只读 OKX Demo 预检核对 REST/公共与私有 WS、账户、规则、余额、仓位、挂单；
      输出不含凭证且不产生订单。
- [x] 当次授权后，至少一笔限定 OKX Demo 订单由本进程链发出并有真实终态与经济 Fill；
      清理后权威核对无 Unknown、挂单、负债、仓位和测试资产敞口。未获授权或未闭合
      时此项保持未完成。

## Out of scope

Binance/Bybit Adapter 与 Testnet、SimulatedVenue 替代验收、Linux 生产资格、
第二套控制面 CLI、通用插件框架和未授权真实订单。

## Historical evidence

2026-09-18 的五进程 SimulatedVenue 结果仅属旧范围；2026-09-27 当前源码
`zig build windows-chain` 失败，且 Gateway/SimulatedVenue 位于 engine 内。

## Progress

2026-09-27：修正激活前意图的拒绝事实断言、将 engine `ready` 移到 owner 初始化后，
并在历史回放加入该拒绝事实。`zig build windows-chain` 已通过，但只输出
`windows_process_chain_verified=blocked historical_simulated_chain=passed`；这不是 OKX 业务证据。
engine 的 `ready` 现在还等待真实 Python `ManagedHost` 完成会话握手；HostActivated 与意图
仍是历史 fixture，不能计入 OKX 业务链验收。
`zig test src/okx_venue_adapter.zig` 60/60、`zig test src/okx_market_feed.zig` 15/15。
`okx-demo-preflight.ps1` 只读 REST 基线通过，`-PrepareOnly` 私有 WS 登录、订阅、
bootstrap 与 baseline 通过，未下单；账户范围与本链的独立进程所有权仍未验收。
当前 Gateway 的公开 `sendFromShard` 要求进程内 `TradingShard`，独立执行进程需要
受源权威约束且可复核的跨进程 DispatchProof 协议，不能改用公开禁用的 `sendProof` 绕过。
已在 `demo_authority.Owner.committedSnapshot` 增加只读的已提交状态快照导出，
并以 `TradingShard.restoreSnapshot` 验证精确 barrier 和 digest；`zig test src/demo_authority.zig`
139/139。该快照尚未跨 Named Pipe 传给 execution-gateway，也不授予发送能力。

2026-09-27 当次[离线与只读证据](../evidence-2026-09-27-offline-readonly.json)绑定 HEAD、
脏工作树相关源码 SHA-256、Zig 版本、模式与脱敏结果。公共 Demo WS `BTC-USDT`
订阅/行情、私有 WS 登录/订阅/bootstrap、REST 规则/余额/仓位/挂单基线实测通过，
只读前后均无挂单、仓位或负债。此证据只关闭各自的连接和适配器检查，
跨进程 OKX 业务链、账户身份绑定、真实成交及磁盘恢复仍为 `blocked`/`not_run`。

2026-09-27 续证据：[离线磁盘回归](../evidence-2026-09-27-offline-disk-followup.json)
用现有 `raw_ingress.DurableSink` 提交 OKX 公共/私有原始帧，让 Gateway 的 DispatchProof 和
Owner 的私有 report、经济 Fill、费用及账户事实进入 WindowsFileAdapter。发送调用从
Owner 的已提交快照恢复并复核 barrier/digest；错误 barrier 在假 transport 写入前拒绝。
关闭并重开文件 Store 后，原始帧可按摘要重放，dispatch barrier 存在，Owner 的终态、20,000 spot atoms、
账户状态和 digest 一致。`zig test src/okx_demo_live_acceptance.zig` 156/156；
`zig test src/main.zig --stack 67108864` 297/297。默认栈的主测试仍在第 82/297 处
栈溢出，不能写作默认命令通过。`zig build windows-chain` 仍仅通过历史 SimulatedVenue
五进程链，并明确输出 `windows_process_chain_verified=blocked`。这项磁盘回归在单进程
假 transport 上运行，不能关闭跨进程 OKX、真实 Host 到 Demo 发送或在线成交验收。
现有 Linux Demo runner 的 `RawSink` 仍只计数，不能作为本票权威 RawIngress 的在线
持久化证据；Windows 业务链必须接入已有 `raw_ingress.DurableSink`，并验证原始输入
重放、账户身份和进程间 fencing 后才能进入授权写阶段。
同日重新执行只读公共 WS 和 `-PrepareOnly`，分别得到 `public_ws=passed order_writes=0`
以及 `private_stream/bootstrap/baseline/observation_only ok`；未发单。随后用户明确授权当前
Demo 账户执行 05 所需的写入和清理，本轮按 BTC-USDT、现有每单 25 USDT 上限自限；
实际发送前还须记录当轮截止时间。只读 `/account/config` 已返回 UID 并由预检输出
SHA-256 指纹；当次无挂单、仓位、负债，只有 USDT 资金。写入尚未开始，因为独立
Windows execution-gateway 与 OKX Adapter 的业务路径未接通；Linux runner 不替代它。

2026-09-28：[离线重放证据](../evidence-2026-09-28-offline-replay.json)为已提交 RawIngress
增加 OKX 公共行情的无写重放入口；磁盘回归在关闭并重开
WindowsFileAdapter 后，按原始帧摘要和原 session 将公共帧重新送入 MarketFeedAdapter，
产出 canonical 行情事实。错误 session/摘要被拒绝，重放 RawSink 写入数为零。
`zig test src/okx_demo_live_acceptance.zig` 156/156，
`zig test src/main.zig --stack 67108864` 297/297。此回归仍在单进程运行，不能替代
五进程 OKX 验收或真实 Demo 成交；05 保持 in-progress。

2026-09-28：历史进程链的决策快照 Named Pipe 帧现携带 owner 的 barrier 与
CanonicalStateDigest；execution-gateway role 在恢复快照后逐项复核。跨进程负例确认错误
barrier 和错误 digest 均返回 failed 并退出；`zig build windows-chain`、
`zig test src/windows_verification_runtime.zig`（9/9）通过。该链仍使用 SimulatedVenue，
不能据此关闭真实 OKX 接线、离线业务链或 Demo 写验收。

2026-09-28：market-feed role 现实际持有 OKX MarketFeedAdapter 和独立 Windows RawIngress
文件 Store。离线 OKX 公共 instruments 原始帧在该子进程先提交，canonical 事件经 generation
校验的有界 Named Pipe 由 controller 原样转交 engine，随后由 Owner 写入决策 Store；关闭并
重开 market Store 后核对原始帧、session 和序号。旧 generation 业务帧跨进程验收失败关闭。
`zig build windows-chain` 通过并仅输出 `okx_market_role=offline_passed`；engine 的下单链与
execution-gateway 仍是 SimulatedVenue，05 保持 `in-progress`，整体 offline 保持 blocked。
role 在处理每个控制命令前重新读取磁盘 generation；进程仍在线时提升 generation 后的
下一命令已通过跨进程负例确认拒绝。
market-feed role 再启动时从已提交 RawIngress 重放 OKX MarketFeedAdapter 状态，且重放
不再次写入 RawIngress；已有历史损坏时启动失败关闭，不从序号 1 重用来源身份。

2026-09-28：独立 execution-gateway role 现持有 OKX VenueAdapter、Gateway、私有
Reconciler、RawIngress 与 DispatchProof 文件 Store；engine 内另一个 Demo Owner 接收
market-feed 的 canonical 行情和执行 role 的 canonical 私有事实。离线五进程链由真实
Python ManagedHost 在 HostActivated 后产出 BTC-USDT spot IOC 意图，owner 持久化
OMS 命令并通过 Named Pipe 交付 barrier/digest 验证的已提交快照；执行 role 经
`sendFromCommittedSnapshot` 调用 OKX Adapter 的可注入假 transport，dispatch 结果、
私有 filled report/Fill、费用和账户快照回到 owner。关闭并重开决策 Store 后，终态、
20,000 spot atoms 和 digest 一致；重复私有成交不改变 digest。
执行 role 重启从原始帧无写重放私有 Adapter 状态；OKX HTTP 响应在 RawIngress 中有
独立来源标记，不再被重放为私有 WS。恢复的 dispatch journal 将既有发送视为
Unknown，跨进程负例确认错误快照 digest 和重放后再次发送均失败关闭，dispatch
commit barrier 未变。`zig build windows-chain`、`zig test src/okx_live_chain.zig`
（35/35）、`zig test src/main.zig --stack 67108864`（297/297）通过。此链仍仅使用
假 transport、固定脱敏帧及两个独立的本地 fencing authority；尚无同一控制权威的
send-time lease 校验、真实 Demo transport/私有流或当次授权成交。整体 offline、
read_only、demo_live 和 WindowsProcessChainVerified 均保持未通过，05 保持 in-progress。

2026-09-28：control-fence role 独占 Windows fencing authority，engine 与独立
execution-gateway 只安装同一 checkpoint/token 的只读视图；Gateway 每次发送前重读
checkpoint。`windows-demo-bin` 接入真实 Curl Demo transport，独立 execution role 实测
账户 UID 指纹、私有 WS 登录/订阅、REST 分页、RawIngress 先提交、Adapter 翻译并经
Named Pipe 将 canonical 事实交给 engine。真实只读运行在 engine 封存决策快照后关停，
重开文件 Store 的 Owner 恢复通过，输出 `windows_demo_readonly=passed ... order_writes=0`。
首次实测发现 RawIngress 16 KiB 段在成交历史第二页耗尽；段上限扩至 64 KiB，
REST 历史分页限 3 行以保持单帧在 4 KiB 内，并新增超过旧段容量的重放检查。
`zig build windows-chain`、`zig test src/raw_ingress.zig --stack 67108864`（23/23）、
`zig test src/main.zig --stack 67108864`（297/297）通过。
这只关闭独立执行 role 的真实只读接线；市场 role 仍用离线帧，真实发送仍由
`explicit_demo_live=false` 拦住，当前固定纳秒 lease/发送时钟不能用于在线下单，
持久化段在持续流量下仍需轮转方案，真实成交、清理和五进程在线验收未完成。

2026-09-28 续：market-feed 子进程改用真实 Demo 公共 WS `books5` 与公共 REST
BTC-USDT 产品规则，RawIngress 先提交再由 MarketFeedAdapter 翻译，经 Named Pipe
交给 engine；执行 role 仍独占私有 REST/WS 和 OKX transport。五个独立 role 的
Demo 只读运行输出 `windows_demo_readonly=passed rest=ok private_ws=ok public_ws=ok
roles=5 order_writes=0`，关停后 engine 决策 Store 重开恢复通过。
控制 role 改用真实单调时钟，等待命令期间持续续期 1 秒 lease；engine 与执行 role
重新安装同一 token 的最新租期并在发送检查中重读控制 checkpoint。真实账户的
显式空字符串负债/保证金字段按零保留，缺失字段仍为 unknown；真实 BTC-USDT
tick/lot 必须与当前执行编码一致。`zig build windows-chain`、
`zig test src/main.zig --stack 67108864`（312/312）通过。
发送仍关闭：现有策略准备写入固定 50,000 美元 mark，Host 固定 IOC 价格，
且核心 mark 与公开行情价格刻度需要统一；尚未证明当前真实价格下的数量/名义上限、
真实终态、清理与零残余。用户已授权 Demo 发送，但这些失败关闭条件未满足，
因此本次没有订单写入，05 继续 in-progress。

同日继续：TradingShard 的 core mark 从微美元按当前已激活 tick 转换为 canonical ticks，
私有 canonical mark 写入经济投影时反向还原微美元；新增刻度回归。
`zig test src/main.zig --stack 67108864`（313/313）及改动后的真实五进程 Demo
只读重跑通过，仍为零订单写入。固定 mark 与 Host IOC 价格尚未改为从真实行情和
price-limit 派生，也没有同链减仓、私有终态及零敞口核对；发送开关继续关闭。

2026-09-29：真实 BTC-USDT 行情、动态 ticker/price-limit 报价、发送时再次核价、
30 分钟写入截止、control-fence 续期、独立 Gateway/OKX transport 已接通并实际发出
三笔各 0.00005 BTC 的 Demo 买单；OKX REST 确认三笔均 filled。三次回合均未完成
同链卖出：首次账户观察超过 8 条使决策日志记录 `capacity_exhausted`，第二次私有 WS
断线，第三次成交后账户对账状态被拒；随后的无成交回合又因 1 秒 dispatch deadline
在核价后过期。每笔残余 0.00004995 BTC 均用受限应急 IOC 卖单清理，三笔卖单
REST 终态均 filled；最新预检 UID SHA-256 为
`e52bb9f5cda58fc03db5ba5b93de42450d7d69030d618c8dd8aae4adc5b70952`，
只有 USDT 余额，BTC、挂单、仓位、负债均为零。应急清理绕过五进程业务链，
不能计入本票的同链减仓验收。

代码已加入账户观察滚动去重窗口、私有 WS 断线后重连并用 REST 补事实、对账完成后
清空 Adapter 输出、192 KiB 有界持久化段、Demo 15 秒 dispatch deadline 和更长的
风险 lease 屏障。`zig test src/main.zig --stack 67108864` 314/314、账户投影定向测试、
Adapter 成交后再次对账测试、超过 8 条账户观察的 Owner 磁盘恢复测试通过；真实五进程
只读及强制 WS 重连测试通过。上述修复尚未完成新的成功 Demo 买卖回合，旧的已失效
日志在账户窗口语义更新后也未证明新版本可直接重放。05 保持 `in-progress`，06 继续
blocked，不声明 WindowsProcessChainVerified 或生产资格。

2026-09-29 完成：经多轮失败关闭与零敞口清理，修正历史终态订单阻塞私有事件排空、
重复 REST 空仓位快照被去重、重连后订阅 ACK 被误拒、手续费扣除后的 BTC 数量产生的
微美元以下名义额计算、USDT 手续费多于 6 位的保守量化、68 条 Trace 容量和
RawIngress 持久化分段回放。最终同一五进程链在当前 Demo 账户发出 BTC-USDT
`0.00005 BTC` 买单（`3965154311785299968`）和按已扣 BTC 手续费后的
`0.00004995 BTC` 卖单（`3965155877300879360`）；两笔 OKX 终态均 `filled`，
私有事实经 Adapter 转为 report、经济 Fill、费用及账户快照并由 engine 应用。
`windows_demo_live=passed`，engine 决策 Store 关闭重开后核对现货净量为零、OMS
订单关闭、账户快照零敞口；后续独立 REST 预检确认只有 USDT，挂单、条件单、仓位、
负债均为零。`zig test src/main.zig --stack 67108864` 319/319、`zig build
windows-chain`、Zig 格式与 diff 检查通过。详见[本轮证据](../evidence-2026-09-29-demo-round-trip.json)。
05 的业务链验收已闭合；`windows_process_chain_verified` 的最终机器报告与精确源码
封存属于 06，当前仍为 `blocked`，生产资格仍为 false。测试前的应急直连卖单均未计入
同链卖出证据。

2026-09-29 审查后复测：controller 校验由同用户 SID 扩展为精确 controller PID，
generation 损坏不再回退为 0，磁盘替换失败不删除旧计数器；engine 启动仅报告
`owner_ready`，Python Host 握手及 HostActivated 完成后才报告 `ready`。telemetry 对
每次 Demo 发送前的 generation 校验存活探测应答。新二进制经五进程只读与授权 Demo
买卖回合再次通过；独立 postflight 确认只有 USDT，挂单、条件单、仓位与负债均为零。
随后补充了 generation 文件尾随字节损坏拒绝测试；这项代码变更未再触发真实订单，
因此最终精确源码绑定留给 06。详见同一证据文件的 `post_review_rerun`。
