# 01 建立 worker 预热基线

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [模块地图](../map.md)

## Question

现有 worker 轮转在三档负载下发出多少次元数据请求，预热耗时是多少？

## What to build

从复用前的版本运行现有离线容量场景，使同一统计口径能在复用启用后复测。

## 验收条件

- [x] 使用正式调度、公共 transport 限频和原生 worker，对 16、64、256 盘口执行离线首轮测量。记录源码版本、构建模式、夹具、负载和运行命令。
- [x] 每档报告元数据实际请求量，区分目录发现和 worker 预热或周期刷新。写明 worker 预热耗时的起止点，覆盖新开和轮转重开的 worker。
- [x] 报告首轮耗时、新鲜覆盖均值与峰值，注明覆盖分母和首轮完成条件。保留结果供 03 对照。

## 测量口径

- 复用前运行时及原生 worker 源码版本为 `265e6a9da4ed5e035df2116895b29a6fcde88040`。Windows NT 10.0.17763，Python 3.9.18，Zig `0.17.0-dev.315+5b647b792`，原生 worker 使用 `ReleaseFast`。工作树中已有的 `strategy_instance.py` 修改位于策略实例切换路径，扫描使用的 `NativeAuthority` 未改动。
- 沿用 [离线容量场景](../../../docs/research/2026-11-22-scanner-capacity.md) 和 [容量脚本](../../../python/verify_scanner_capacity.py) 的合成协议夹具。每档在新的临时状态目录启动，`TOKEN0` 起生成 8、32、128 对路线，每对一条 OKX production 现货腿和一条 Hyperliquid production 标准永续腿。OKX 另发现 SWAP 目录。扫描使用正式调度、公共 transport 限频、原生解码和 DurableStore。活动盘口 worker 上限为 16，每 Venue 最多 2 个在途采样任务。OKX 请求间隔 100 ms，Hyperliquid 元数据间隔 1.2 s，盘口和批量报价间隔 120 ms。
- 在夹具的 HTTP opener 收到请求时计数，按初始目录发现、启扫后目录刷新、worker 预热和 worker 周期刷新归属。生产调度已有的共享请求按实际进入 opener 的次数计数。统计截至采样循环观察到首轮完成时，停扫和归档收尾期间发出的请求不计入。
- 单次 worker 预热从进入 worker 打开路径、启动原生进程前开始，到原生 worker 返回成功订阅确认为止。时长含进程初始化、等待和校验元数据以及订阅确认，首条盘口采样随后进行。同一 Instrument 路线腿第一次打开计为初开，其后轮转或重启产生的打开计为重开。时长统计使用截止时已有成功确认的样本，另记录尝试总数。该 Windows 运行的单调时钟样本呈现约 15.6 ms 的步进。
- 首轮从调度建立覆盖轮次起计。每条发现路线都须在该轮起点之后采得连续健康的双腿盘口，双腿时差最多 1 秒。每 500 ms 采样新鲜覆盖，分母是该档发现路线数，分子要求盘口年龄小于 5 秒、双腿时差最多 1 秒、行情健康且规则有效。均值和峰值取到首次观察到该轮完成。

在仓库根目录运行以下 PowerShell 命令。预热与覆盖后续对照沿用同一容量入口。

```powershell
New-Item -ItemType Directory -Force .scratch/build/scanner-warmup-baseline | Out-Null
python tools/zig-entry.py build-exe src/runtime/scanner_market_node.zig -O ReleaseFast --stack 536870912 '-femit-bin=.scratch/build/scanner-warmup-baseline/ringwin-scanner-market.exe'
python python/verify_scanner_capacity.py --seconds 420 --rounds 1 --selected 16 64 256 --worker .scratch/build/scanner-warmup-baseline/ringwin-scanner-market.exe | Tee-Object -FilePath .scratch/build/scanner-warmup-baseline/results.jsonl
```

原生 worker SHA-256 为 `65C9F5EA46366217CD72B41ABFCB2EBF0BF695B28A689246CC87BD89E4304161`。
容量脚本 Git blob 为 `677e1212a37880e089d28fc717f65b3d0a37e546`。

## 首轮实测

| 盘口 | 发现路线 | 首轮耗时（s） | 新鲜覆盖均值 | 新鲜覆盖峰值 |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 8 | 12.765 | 20.19% | 37.50% |
| 64 | 32 | 84.297 | 5.66% | 12.50% |
| 256 | 128 | 206.781 | 1.74% | 3.91% |

元数据请求次数按 Venue 和用途列出。合计包含启扫前的初始目录发现，三档均未收到 429。

| 盘口 | Venue | 初始目录 | 目录刷新 | worker 预热 | worker 周期刷新 | 合计 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16 | OKX | 2 | 0 | 8 | 0 | 10 |
| 16 | Hyperliquid | 1 | 0 | 7 | 0 | 8 |
| 64 | OKX | 2 | 4 | 61 | 0 | 67 |
| 64 | Hyperliquid | 1 | 2 | 44 | 0 | 47 |
| 256 | OKX | 2 | 12 | 131 | 0 | 145 |
| 256 | Hyperliquid | 1 | 6 | 104 | 0 | 111 |

worker 预热时长以毫秒记录，取整到最近的毫秒。截止时未确认的尝试只计入尝试总数。

| 盘口 | Venue | 打开类型 | 确认 / 尝试 | 均值（ms） | 中位数（ms） | 最小–最大（ms） |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 16 | OKX | 初开 | 8 / 8 | 234 | 234 | 156–343 |
| 16 | OKX | 重开 | 0 / 0 | — | — | — |
| 16 | Hyperliquid | 初开 | 8 / 8 | 844 | 1102 | 266–1297 |
| 16 | Hyperliquid | 重开 | 0 / 0 | — | — | — |
| 64 | OKX | 初开 | 32 / 32 | 490 | 430 | 203–969 |
| 64 | OKX | 重开 | 29 / 29 | 611 | 469 | 234–2656 |
| 64 | Hyperliquid | 初开 | 32 / 32 | 738 | 719 | 219–1266 |
| 64 | Hyperliquid | 重开 | 28 / 29 | 778 | 640 | 234–2766 |
| 256 | OKX | 初开 | 128 / 128 | 449 | 422 | 172–922 |
| 256 | OKX | 重开 | 3 / 3 | 661 | 562 | 531–891 |
| 256 | Hyperliquid | 初开 | 128 / 128 | 725 | 625 | 235–2047 |
| 256 | Hyperliquid | 重开 | 3 / 3 | 677 | 734 | 531–766 |
