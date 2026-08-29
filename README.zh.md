# Ringwin 量化交易引擎产品原型

这是一个可执行的 Zig 交易引擎纵向闭环，并包含显式授权下的 OKX Demo Trading 验收；它不是生产交易系统。

当前原型用一个模拟 Venue、一个 Gate.io 形状的 `BTC_USDT` USDT 线性永续品种、
一个 VirtualPortfolio、一个 ExchangeAccount 和一个静态编译原生策略，证明：

- 同一 `TradingShard` 状态转换可以用于实时、仿真驱动和日志重放。
- 行情、策略、定点风控、订单、双层仓位、账本、费用和 PnL 能形成闭合事实链。
- 行情缺口、风险拒绝、Unknown 对账和重复回报走同一个核心状态机。
- 四个 `TradingShard` 实例可以保持独立状态、日志、队列和故障边界。

默认路径不连接真实 Venue；独立入口只使用本机 Demo Key 连接 OKX 模拟交易。项目不接入生产账户，也不证明策略盈利。

## 交易核心整波验收

一条失败即停的自动入口覆盖离线成功/故障/重启轨迹、SimulatedVenue、四分片协调、
Python StrategyHost seam 和 Linux 交叉编译检查；OKX Demo 事实只在显式启用时执行：

```powershell
tools\verify-core-wave.ps1
```

任一断言失败立即停止。成功输出 `core_wave_acceptance=passed mode=offline ...`。
显式启用 OKX Demo 成交事实时追加 `-DemoLive`（要求 `.env.local` 中合格的 Demo Key）。

## OKX Demo 整波验收

默认入口只读，但仍要求本机 `.env.local` 中存在合格的 Demo Key：

```powershell
tools\verify-okx-demo-wave.ps1
```

它失败即停，验证精确 Zig/libcurl 版本、格式、Debug/ReleaseSafe/ReleaseFast 核心合同、
确定性摘要、公共 HTTPS、Demo private WSS 与分页 REST 对账，并完成 `x86_64-linux-gnu`
compile-only 检查。成功输出：

```text
okx_demo_wave_acceptance=passed mode=read_only linux=compile_only production_qualification=false
```

只有 SystemOwner 明确允许 Demo 成交时才运行：

```powershell
tools\verify-okx-demo-wave.ps1 -DemoLive
```

它额外执行固定 BTC-USDT IOC 策略、真实 Demo 回报、反向清理、经济投影与稳定重放，
并在结束时再次验证零挂单、零仓位、零负债及无 BTC 残余。异常后不得重复普通入口；若
preflight 只报告 BTC 残余，使用 `tools\run-okx-demo-live-acceptance.ps1 -CleanupOnly`。
凭证只从被 Git 忽略的 `.env.local` 临时注入，不进入命令行或输出。

该入口只证明 Windows Demo 功能和 Linux 源码可交叉编译；不证明 Linux 运行时/性能、
策略收益、生产账户或生产部署资格。

## 环境

- Zig `0.17.0-dev.315+5b647b792`
- Python 3.9 或更新版本
- 仅使用 Zig 与 Python 标准库
- 权威金额、价格、数量、费率、保证金和 PnL 使用定点整数；`f64` 不参与状态演进

先确认版本：

```powershell
zig version
```

## 最小功能验收

从仓库根目录执行：

```powershell
zig fmt --check src\main.zig src\trading_shard.zig src\oms.zig src\risk.zig src\journal.zig src\venue_adapter.zig src\okx_public_market.zig
zig test src\main.zig -O ReleaseSafe
zig run src\main.zig -O ReleaseSafe
```

测试应通过三项检查：

```text
all authoritative acceptance traces close and replay
four shards replay and isolate overload
stable journal detects tail, corruption, and sequence gap
```

正常演示固定输出的关键结果：

```text
happy_path: events=34, order=filled, qty=100, open_cost=500200000, fees=375150,
upl=1800000, risk_remaining=9988956000, ledger=closed, economic_projections=complete
journal_records=34
replay=equivalent
digest=674ff4b1e0018280a198b85b580d4e9d5da46ee81cb034783f9d4f637765b7d6
```

失败轨迹固定摘要：

| 轨迹 | 事实数 | CanonicalStateDigestV3 |
|---|---:|---|
| Market gap | 25 | `9f7890e42b707ce31803f50af9c53e359a13b9b45c0685f497129a731cf5dbad` |
| Risk rejection | 21 | `ff1d46e6c479eff7e25a7c00fd0750d92bdb0da09eab5923e3fb19dc179315e1` |
| Unknown reconciliation | 26 | `2ce777b8a2625b2c0e9d44aea74f12e2395d81092fba6c154bd4b3ba5a1129da` |
| Duplicate report | 35 | `e45ce49f98a7ae623bee6e4eedbef70f3afa0901692f7340c823540265371d54` |

`zig test` 还会验证：

- 账本借贷闭合、PortfolioPosition 与 ExchangePosition 一致；
- 实时事实序列、重放事实序列和最终摘要一致；
- 截断尾部安全恢复，CRC 损坏、序号缺口和未知 schema 失败关闭；
- 重复成交、订单回报、取消和对账不重复改变经济状态；
- 同一分片内 BTC-USDT SPOT 与 isolated/net USDT SWAP 的有界多订单 place/amend/cancel、
  IntentGroup 部分执行、逐项 batch、Unknown 对账及授权 CancelConfirmCreate 可稳定重放；
- SPOT 现金和 SWAP 逐仓保证金、费用缓冲、五层额度、双 Reduce-only 与三档 MarginSafetyGate
  在 OrderCommand 前由核心纯定点计算；调用方不能指定 reservation，Unknown 不提前释放。
- 四个 DecisionDomain 分别重放等价；
- 一个分片的行情 Gap、慢消费者和队列饱和不改变其他分片的顺序及健康状态。
- OKX 固定 SPOT/SWAP 白名单的 Instrument、L2、标记价、指数价和资金费率只以定点数
  标准化，RawIngress 先于解析提交；重复、损坏、断档和重订阅均失败关闭并等待新快照。

## Python StrategyHost 完整验收

从仓库根目录执行一条命令：

```powershell
python python\verify_strategy_host.py
```

该入口失败即停，自动完成格式检查、IPC/生命周期/Gateway/checkpoint/故障单元测试，
构建当前平台共享内存桥，并运行四 Host 生命周期、TradingShard 交易接入、无权恢复重放、
故障矩阵以及五个百万样本容量场景。最终输出：

```text
strategy_host_product_acceptance=passed
```

它只证明 StrategyHost 产品 seam：Python 只拥有显式 schema 的策略私有状态，输出仍是
待验证的 `OrderIntent`；权威订单、仓位、账本、风险与 OMS 始终属于 Zig TradingShard。
该命令不连接真实 Venue，也不会把 Windows 开发回归升级为 Linux 生产资格。

## Python StrategyHost IPC 验收

首个产品化组件是 Zig 拥有的匿名共享内存与冻结 C ABI；Python 只能通过
`ctypes` 调用桥，不能直接接触槽位或原子游标。

```powershell
zig fmt --check src\strategy_host_ipc.zig
zig test src\strategy_host_ipc.zig -O ReleaseSafe
zig run src\strategy_host_ipc.zig -O ReleaseSafe
zig build-lib src\strategy_host_ipc.zig -dynamic -O ReleaseSafe
```

自检覆盖双向传输、批序号、CRC32C、满/空、wrap-around、批量发布原子性、旧会话、
损坏失败关闭和父子进程可见性。正常输出为：

```text
strategy_host_ipc: zig=0.17.0-dev.315+5b647b792, mode=ReleaseSafe,
self_check=ok, cross_process=ok
```

Windows 使用匿名 File Mapping；Debian 生产目标使用匿名 `memfd`，Linux 路径由
`x86_64-linux-gnu` 交叉编译检查。实际 ring 深度和 slot capacity 留给容量资格票测量。

## Python StrategyHost 生命周期验收

`HostSupervisor` 通过两条匿名控制 pipe 启动并监督一分片一 Host；`HostHello`
精确匹配后只进入 `ready_for_recovery`，此时仍没有交易权限。

```powershell
zig fmt --check src\strategy_host_lifecycle.zig
python -m py_compile python\strategy_host.py
zig test src\strategy_host_lifecycle.zig -O ReleaseSafe
zig run src\strategy_host_lifecycle.zig -O ReleaseSafe
```

可执行检查同时启动四个 Python Host，并覆盖正常握手/停止、协议与构建不兼容、
进程崩溃、主循环心跳卡死、全新 generation 重建，以及旧 session 的 intent、
确认和 checkpoint 包络拒绝。正常输出为：

```text
strategy_host_lifecycle: hosts=4, handshake=ok, stop=ok,
crash_rebuild=ok, hang_rebuild=ok, stale_session=blocked
```

启动超时、心跳周期、卡死超时和停止宽限期由 `SessionPlan` 提供，当前检查值只属于 fixture，
不构成生产资格常量。多策略恢复编排与完整失败矩阵由后续 frontier 完成。

## Python StrategyHost 到 TradingShard 验收

订阅事件先按同一 Host 内策略的订阅并集过滤，再以稳定批次编码写入核心拥有的 SPSC；
Python 返回的 `OrderIntentV1` 会重新校验 session、schema、activation、cursor 和 100 ms
新鲜度，并与原生 intent 共用同一个定点风控、订单和事实投影入口。

```powershell
zig build-lib src\strategy_host_ipc.zig -dynamic -O ReleaseSafe `
  '-femit-bin=.scratch/build/strategy_host_ipc-current.dll'
zig run src\strategy_host_integration.zig -O ReleaseSafe -- `
  '.scratch/build/strategy_host_ipc-current.dll'
```

通过时输出：

```text
strategy_host_integration: subscriptions=merged, python_intent=accepted, native_risk_path=ok, stable_rejections=7
```

## Python StrategyHost checkpoint 恢复验收

`CheckpointContainer v1` 使用显式元数据、规范 JSON、CRC32C 与 SHA-256；Python Host
从 checkpoint 无权重放分片日志，核心核对 `StrategyStateDigest` 并记录 activation
后才开放 Gateway。恢复期间的输出即使格式合法也会在风控前拒绝。

```powershell
zig test src\strategy_host_recovery.zig -O ReleaseSafe
zig run src\strategy_host_recovery_integration.zig -O ReleaseSafe -- `
  '.scratch/build/strategy_host_ipc-current.dll'
```

通过时输出：

```text
strategy_host_recovery: checkpoint=validated, replay=equivalent, pre_activation_intents=0, recovered_intent=stable
```

## Python StrategyHost 故障矩阵

四个真实 Host 的自动化轨迹覆盖单策略异常、进程崩溃、不可抢占卡死、输出通道满、
输入 schema 损坏、旧 session 迟到和 checkpoint 回退；故障 Host 会先撤权再重建，
健康 Host 的 cursor 继续推进，跨 session 的业务 intent 身份仍只接受一次。

```powershell
zig test src\strategy_host_failures.zig -O ReleaseSafe
zig run src\strategy_host_failure_integration.zig -O ReleaseSafe -- `
  '.scratch/build/strategy_host_ipc-current.dll'
```

通过时输出：

```text
strategy_host_failures: hosts=4, strategy_fault=isolated, crash=rebuilt, hang=killed, output_full=fenced, input_invalid=fenced, healthy_cursor=continuous, duplicate_intents=0
```

## Python StrategyHost 容量开发回归

容量程序通过产品共享内存 seam 启动四个 Host、每 Host 25 个标准库整数状态策略；
每批 10 个 TimerEvent，每个策略/事件回调算一个决策样本。正常、GC/单策略异常、
单 Host 变慢、Host 崩溃和恢复负载各自至少采集 100 万样本。

```powershell
zig build-exe src\strategy_host_capacity.zig -O ReleaseSafe `
  '-femit-bin=.scratch/strategy_host_capacity.exe'
.\.scratch\strategy_host_capacity.exe `
  '.scratch\build\strategy_host_ipc-current.dll'
```

Windows i5-4200U 开发回归的五个场景均满足 Python P99 `<= 50 ms`、P99.9
`<= 100 ms`，且 input full、拒绝、stale 和恢复意图为零。与四分片基准并发时，
Python 仍满足合同；但该 2C/4T 节点的 TradingShard 基线本就不合格，并发 P99
由 `2.0345 ms` 增至 `8.2305 ms`，不能据此授予 Linux 产品资格。Linux 桥和容量
程序已通过 `x86_64-linux-gnu` 交叉构建，运行时资格留给具备四个分片专用物理核
及外围 CPU 容量的 Linux 节点。

完整记录：[四 Host/百策略原始结果](.scratch/python-strategy-host-productization/benchmarks/07-windows-raw.txt)。

## 单分片开发基准

```powershell
zig build-exe src\main.zig -O ReleaseFast '-femit-bin=.scratch/single-shard-benchmark.exe'
.\.scratch\single-shard-benchmark.exe --benchmark
.\.scratch\single-shard-benchmark.exe --benchmark-raw
```

它分别运行稳态、行情突发、订单突发和异常恢复，每个场景至少 1,000,000 样本，
并输出 P50、P99、P99.9、Max、吞吐、队列最高水位、桶溢出和正确性失败数。

Windows i5-4200U 开发基线中：

- 稳态核心 P99 为 `1 us`；
- 单分片最低持续吞吐为 `1.66M events/s`；
- 订单突发 P99 为 `34–36.5 us`；
- Windows 调度长尾使订单 P99.9 未能连续满足 `100 us`。

完整记录：

- [单分片性能结论](.scratch/quant-trading-engine-vertical-slice/issues/06-single-shard-performance.md)
- [单分片原始直方图](.scratch/quant-trading-engine-vertical-slice/benchmarks/06-single-shard-windows-raw.txt)

## 四分片开发基准

```powershell
zig build-exe src\main.zig -O ReleaseFast '-femit-bin=.scratch/four-shard-benchmark.exe'
.\.scratch\four-shard-benchmark.exe --benchmark-four-shard
.\.scratch\four-shard-benchmark.exe --benchmark-four-shard-raw
```

共享生产者按 DecisionDomain 定向写入四条独立 SPSC 队列；四个 worker 使用相同的
`TradingShard` 实现。基准按独立计划时间发送聚合 `2M events/s`，迟发后继续追赶，
不隐藏排队突发。

Windows 2C/4T 开发节点接近 `2M events/s`，但四分片合并 P99 为
`0.961–2.348 ms`，不能通过生产延迟资格。该节点缺少
“4 个分片专用物理核 + 至少 1 个共享路由/I/O 核”。

完整记录：

- [四分片资格结论](.scratch/quant-trading-engine-vertical-slice/issues/07-four-shard-qualification.md)
- [四分片原始直方图](.scratch/quant-trading-engine-vertical-slice/benchmarks/07-four-shard-windows-raw.txt)

生成的 `.exe` 和 `.pdb` 只是本地构建产物，不属于权威证据。

## 已证明与未证明

已由自动检查证明：

- 单写者 `TradingShard` 的确定性业务闭环；
- L2 健康/缺口、TimerEvent、原生策略、OrderIntent、定点风险和 OrderCommand；
- 接受、部分成交、完全成交、Unknown 与对账；
- 双层仓位、账本、手续费、移动加权成本和 PnL 闭合；
- 稳定版本化日志、CRC32C、截断恢复、损坏检测和重放等价；
- 幂等经济事实和四分片局部过载隔离；
- Python StrategyHost 的产品 SPSC IPC、会话 fencing、TradingShard 再验证与同一路径
  定点风险/OMS；
- PortableStrategyState checkpoint、无交易权限日志追赶、恢复屏障，以及策略异常、
  Host crash/hang、输入损坏、输出满和旧会话隔离；
- 四 Host、约百个标准库策略在五种场景中的 Windows 百万样本开发回归。

仅在当前 Windows 开发节点测量：

- 单分片和四分片延迟分布、吞吐及队列水位；
- 四分片静态内存增长；
- Python StrategyHost 的约百策略容量、延迟、GC/异常、慢 Host、崩溃和恢复分布；
- 上述数字只用于开发回归，不能成为生产资格证据。

尚未实现或资格化：

- OKX 生产账户、Linux 运行时/性能和部署资格；单命令 Windows Demo 整波与 Linux
  compile-only 证据已经通过；
- Binance、Gate.io、Bitget 的真实行情与交易适配器；当前路线明确不继续扩展 Adapter；
- Python StrategyHost 与四分片核心在合格 Linux 节点上的产品性能资格；
- Linux 独占核心、CPU affinity、NUMA、真实网络/日志 I/O 和硬件性能计数器；
- testnet 协议资格、生产密钥、单活热备、fencing 和部署；
- 多资产、现货、期权、组合保证金、跨分片多腿原子决策和 SOR。

详细业务词汇和不变量见 [CONTEXT.md](CONTEXT.md)，架构关系见
[动态架构图](docs/trading-engine-architecture.html)，本阶段完整决策路线见
[纵向闭环 Wayfinder 地图](.scratch/quant-trading-engine-vertical-slice/map.md)。

## 已完成能力波次与下一步

SystemOwner 已确认
[Python StrategyHost 产品化接入](.scratch/python-strategy-host-productization/map.md)和
[OKX Venue Adapter 最小纵向接入](.scratch/okx-venue-adapter/map.md)能力波次完成。

OKX 波次完成了 v5/传输研究、
Demo 账户安全资格、首个四操作 VenueAdapter seam、OKX 公共 Instrument/L2/参考价/资金费率
标准化、私有 ExecutionReport/Fill/账户事实和 REST 双读恢复屏障，以及完整订单 codec、受保护
Market、原地 amend、逐项 batch 和安全优先有界调度；现有 SimulatedVenue 已只通过该 seam 接收
OrderCommand、返回 dispatch 与 ingress。显式授权的 BTC-USDT Demo 成交/清理验收可运行
`tools\run-okx-demo-live-acceptance.ps1 -DemoLive`；它固定使用 Demo endpoint/header、USDT-only
零 BTC baseline、两轮 REST 稳定屏障、25 USDT 上限和最终零残余预检；固定策略已真实穿过
Gateway、TradingShard 现金风控、OrderCommand、OKX 回报、经济投影与稳定重放。断连、L2 缺口、
认证失败、限流、Unknown、部分成功、并发 Fill、REST 分页、迟到事实和清理失败矩阵也已闭合；
整波自动资格、异常关机后复验与最终证据边界均已闭合。

现有 OKX Adapter 已足够验证真实 Venue 业务闭环，SystemOwner 明确停止继续扩展 Adapter。
下一能力波次转入[交易核心系统闭环](.scratch/trading-core-system-closure/map.md)：补齐核心拥有的
多品种 OMS、风险与账务、操作安全栅栏、持久恢复、分片/账户协调及同核整波验收。OKX 仅作为
既有真实 Venue 证据；Linux 五核生产性能、生产账户、密钥托管和部署资格仍是独立波次。

## License

Ringwin is licensed under the [MIT License](LICENSE).
