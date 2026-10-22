# Ringwin 量化交易引擎产品原型

这是一个可执行的 Zig 交易引擎纵向闭环，并包含显式授权下的 OKX Demo Trading 验收；它不是生产交易系统。

当前原型用模拟 Venue 以及统一的 OKX、Binance、Bybit Adapter seam，覆盖规范 SPOT 与
`isolated linear USDT` 品种、
一个 VirtualPortfolio、一个 ExchangeAccount 和一个静态编译原生策略，证明：

- 同一 `TradingShard` 状态转换可以用于实时、仿真驱动和日志重放。
- 行情、策略、定点风控、订单、双层仓位、账本、费用和 PnL 能形成闭合事实链。
- 行情缺口、风险拒绝、Unknown 对账和重复回报走同一个核心状态机。
- 四个 `TradingShard` 实例可以保持独立状态、日志、队列和故障边界。

默认路径不连接真实 Venue；独立入口只使用本机 Demo Key 连接 OKX 模拟交易。项目不接入生产账户，也不证明策略盈利。三家 Venue 的离线 canonical/adapter 契约已接入；真实 Testnet/生产资格仍是独立阶段。

## 统一构建入口

模块归属、完整文件迁移表和独立 Zig 验收命令见[源文件目录说明](docs/source-layout.md)。

仓库统一通过 `build.zig` 执行；每个入口都会先精确验证 Zig
`0.17.0-dev.315+5b647b792`。

```powershell
zig build
zig build test
zig build run -- --offline-fixture
zig build core-wave
zig build demo-wave
```

`core-wave` 执行完整离线回归。`demo-wave` 是显式 OKX Demo wave，默认只做只读准备；只有
SystemOwner 授权 Demo 成交时才执行：

```powershell
zig build demo-wave -Ddemo-live
```

既有 PowerShell 验收脚本仍作为上述 wave 的底层实现。

Linux 生产入口使用同一个签名二进制的显式 role dispatcher。WSL/Linux 原生 ELF 可运行五 role
进程链，验证 Unix domain IPC、有界队列、正常 drain、SIGTERM forced-stop、风险撤销和 generation
重启恢复：

```bash
zig build-exe src/main.zig -target x86_64-linux-gnu -OReleaseSafe -femit-bin=ringwin
./ringwin --production-chain-test
./ringwin --durable-store-test
./ringwin --credential-store-test
```

`--credential-store-test` 验证 Linux-only `CredentialStore`：Argon2id/XChaCha20-Poly1305 认证
metadata、Observation/Execution 凭证分文件、单向生命周期、锁页与禁止 dump 自检、节点和固定
出口 IP 匹配，以及只读 `Ready` 准入。它不会启用交易，也不会输出凭证字节；目标节点的密钥扫描、
RLIMIT_MEMLOCK、core dump、真实生产账户和资格仍需独立证据。

systemd 模板位于 [`deploy/systemd`](deploy/systemd)；每个 role 使用独立 `ringwin-%i` 用户和
runtime directory。基础 unit 只允许 Unix socket，只有 execution-gateway drop-in 放开 Internet
address family。

## 交易核心整波验收

一条失败即停的自动入口覆盖离线成功/故障/重启轨迹、SimulatedVenue、四分片协调、
Python StrategyHost seam 和 Linux 交叉编译检查；OKX Demo 事实只在显式启用时执行：

```powershell
tools\verify-core-wave.ps1
```

任一断言失败立即停止。成功输出由子验收实际结果汇总的 `core_wave_evidence={...}` JSON；当前离线 schema 为 2，Testnet 未运行。

## 环境

- Zig `0.17.0-dev.315+5b647b792`
- Python 3.9 或更新版本
- 仅使用 Zig 与 Python 标准库
- 权威金额、价格、数量、费率、保证金和 PnL 使用定点整数；`f64` 不参与状态演进

Windows 与 Linux 均可独立取得生产资格。当前代码仍实现 Linux-only 生产合同，Windows 生产
准入与资格尚待实现和验收；现有 Windows Demo 验证不能授予 `production_qualified`。合同见
[ADR 0010](docs/adr/0010-qualify-windows-and-linux-independently.md)
与 [`.scratch/windows-process-chain-verification/map.md`](.scratch/windows-process-chain-verification/map.md)。
Linux 生产地图仍是 [`.scratch/production-readiness/map.md`](.scratch/production-readiness/map.md)。

先确认版本：

```powershell
zig version
```

## 最小功能验收

从仓库根目录执行：

```powershell
zig fmt --check src\main.zig src\trading\trading_shard.zig src\execution\oms.zig src\risk\risk.zig src\persistence\journal.zig src\execution\venue_adapter.zig src\adapters\okx\okx_public_market.zig
zig test src\main.zig -O ReleaseSafe
zig run src\main.zig -O ReleaseSafe
```

测试应通过三项检查：

```text
all authoritative acceptance traces close and replay
four shards replay and isolate overload
stable journal detects tail, corruption, and sequence gap
```

当前 schema 版本以 [`src/runtime/production_contract.zig`](src/runtime/production_contract.zig) 为准。
四分片证据由 `zig build run -- --four-shard-acceptance` 输出。重放无发送能力。
Windows 验证入口：

```powershell
zig build windows-durable
zig build windows-credential
zig build windows-chain
zig build windows-okx-offline
zig build windows-okx-readonly
```

当前 `windows-chain` 包含历史 SimulatedVenue 五进程生命周期回归，输出
`historical_simulated_chain=passed` 与 `windows_process_chain_verified=blocked`。
同一入口的 OKX 假 transport 五进程路径、磁盘重开和重放通过后，另行输出
`windows_okx_offline=passed`；历史综合行仍保持 blocked。
新证据须分别通过离线、
在线只读、当次授权的 Demo 真实成交，以及 role 所有权、磁盘恢复和最终账户对账，并绑定
源码 revision、账户、产品、策略和配置。`.env.local` 只是 Demo 凭证输入，不授权下单或清理。
Windows 结果不能使 `permitsProduction()` 为 true，也不能关闭 Linux 生产地图票 02–11。
离线与只读入口分别写入 `.scratch/windows-process-chain-verification/report-offline.json`
和 `report-readonly.json`，并核对同一源码快照及 Demo 账户指纹；默认不下单。
当次 SystemOwner 明确限定授权后，才可运行 `zig build windows-okx-live
-Dwindows-demo-live-authorized=true`。该入口要求匹配的离线、只读报告，并写入
`report-demolive.json`；缺项或未闭合的终态与零敞口不能授予通过结论。

[06 封存证据](.scratch/windows-process-chain-verification/report-demolive-2026-10-03-recovered.json)
限定执行版本 `9939110d` 的获授权 OKX Demo BTC-USDT spot 同链买卖。
原报告解析失败保留，缺失的 wire 订单身份由同次存储恢复和权威只读查询补齐；
采集器身份单独记录。后续运行时修改不继承该在线资格，生产资格仍为 false。

正常轨迹实际摘要：

```text
happy_path: events=34, order=filled, qty=100, open_cost=500200000, fees=375150,
upl=1800000, risk_remaining=9988956000, ledger=closed, economic_projections=complete
journal_records=34
replay=equivalent
digest=06fbeb256cfb02360c40668a8ccc34de0d4c8a532a1e0b1ebd4ff50b683c1048
```

失败轨迹固定摘要：

| 轨迹 | 事实数 | CanonicalStateDigestV3 |
|---|---:|---|
| Market gap | 24 | `b95c50d8d0b8c79b2b82f5191bb4ee031bac8369ebf4f838ff1bc80f86da4cdc` |
| Risk rejection | 21 | `dded7fe60cc6693de322664fbf66b00ee05d177e990c3830644961a6ad514850` |
| Unknown reconciliation | 26 | `103e070525340114edb9fae1bd5c3b880f29c01b990f0fdf4ed3dd45adb938d4` |
| Duplicate report | 34 | `06fbeb256cfb02360c40668a8ccc34de0d4c8a532a1e0b1ebd4ff50b683c1048` |

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
构建当前平台 Zig 校验匿名 pipe 桥，并运行四 Host 生命周期、TradingShard 交易接入、无权恢复重放、
故障矩阵以及五个百万样本容量场景。最终输出：

```text
strategy_host_product_acceptance=passed
```

它只证明 StrategyHost 产品 seam：Python 只拥有显式 schema 的策略私有状态，输出仍是
待验证的 `OrderIntent`；权威订单、仓位、账本、风险与 OMS 始终属于 Zig TradingShard。
该命令不连接真实 Venue，也不会把 Windows 开发回归升级为 Linux 生产资格。

## Python StrategyHost IPC 验收

首个产品化数据面是 Zig 拥有、经校验的匿名单向 pipe 帧（[ADR 0007](docs/adr/0007-use-validated-pipes-for-strategy-host-data.md)）；
Python 只获得自有 `bytes`，不能获得共享内存句柄、映射大小或原子游标。

```powershell
zig fmt --check src\strategy\strategy_host_ipc.zig
python tools/zig-entry.py test src\strategy\strategy_host_ipc.zig -O ReleaseSafe
python tools/zig-entry.py run src\strategy\strategy_host_ipc.zig -O ReleaseSafe
python tools/zig-entry.py build-lib src\strategy\strategy_host_ipc.zig -dynamic -O ReleaseSafe
```

自检覆盖双向传输、批序号、CRC32C、满/空、wrap-around、批量发布原子性、旧会话、
损坏失败关闭和父子进程可见性。正常输出为：

```text
strategy_host_ipc: zig=0.17.0-dev.315+5b647b792, mode=ReleaseSafe,
self_check=ok, cross_process=ok
```

Windows 与 Linux 数据面都使用 Zig 校验的匿名 pipe；Python 没有映射或游标能力。
实际容量留给后续资格票测量。

## Python StrategyHost 生命周期验收

`HostSupervisor` 通过两条匿名控制 pipe 启动并监督一分片一 Host；`HostHello`
精确匹配后只进入 `ready_for_recovery`，此时仍没有交易权限。

```powershell
zig fmt --check src\strategy\strategy_host_lifecycle.zig
python -m py_compile python\strategy_host.py
python tools/zig-entry.py test src\strategy\strategy_host_lifecycle.zig -O ReleaseSafe
python tools/zig-entry.py run src\strategy\strategy_host_lifecycle.zig -O ReleaseSafe
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
python tools/zig-entry.py build-lib src\strategy\strategy_host_ipc.zig -dynamic -O ReleaseSafe `
  '-femit-bin=.scratch/build/strategy_host_ipc-current.dll'
python tools/zig-entry.py run src\testing\integration\strategy_host_integration.zig -O ReleaseSafe -- `
  python python/strategy_host.py
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
python tools/zig-entry.py test src\strategy\strategy_host_recovery.zig -O ReleaseSafe
python tools/zig-entry.py run src\testing\integration\strategy_host_recovery_integration.zig -O ReleaseSafe -- `
  python python/strategy_host.py
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
python tools/zig-entry.py test src\strategy\strategy_host_failures.zig -O ReleaseSafe
python tools/zig-entry.py run src\testing\integration\strategy_host_failure_integration.zig -O ReleaseSafe -- `
  python python/strategy_host.py
```

通过时输出：

```text
strategy_host_failures: hosts=4, strategy_fault=isolated, crash=rebuilt, hang=killed, output_full=fenced, input_invalid=fenced, healthy_cursor=continuous, duplicate_intents=0
```

## Python StrategyHost 容量开发回归

容量程序通过产品 StrategyHostFramedBridge seam 启动四个 Host、每 Host 25 个标准库整数状态策略；
每批 10 个 TimerEvent，每个策略/事件回调算一个决策样本。正常、GC/单策略异常、
单 Host 变慢、Host 崩溃和恢复负载各自至少采集 100 万样本。

```powershell
python tools/zig-entry.py build-exe src\testing\acceptance\capacity\strategy_host_capacity.zig -O ReleaseSafe `
  '-femit-bin=.scratch/strategy_host_capacity.exe'
.\.scratch\strategy_host_capacity.exe `
  python python/strategy_host.py
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
- Binance 与 Bybit 的真实 Testnet/生产账户资格；离线 adapter 与 canonical 契约已通过，不能替代真实运行证据；
- Python StrategyHost 与四分片核心在合格 Linux 节点上的产品性能资格；
- Linux 独占核心、CPU affinity、NUMA、真实网络/日志 I/O 和硬件性能计数器；
- testnet 协议资格、生产密钥、单活热备、fencing 和部署；
- 多资产、现货、期权、组合保证金、跨分片多腿原子决策和 SOR。

详细业务词汇和不变量见 [GLOSSARY.md](GLOSSARY.md)，架构关系见
[动态架构图](docs/trading-engine-architecture.html)，当前修复波次证据见
[交易核心完整性修复地图](.scratch/trading-core-integrity-repair/map.md)。



## License

Ringwin is licensed under the [MIT License](LICENSE).
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/getSilver/Ringwin)
