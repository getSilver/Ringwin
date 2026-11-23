# 01 双腿就绪后协调采样

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [模块地图](../map.md)

## Question

怎样避免快腿在慢腿尚未完成预热时采样，导致路线因双腿时差超限而无法评估？

## What to build

分开 worker 预热与盘口采样。需要采集双腿的路线在两腿均完成原生校验后，按各来源限频预算的最早可请求时间协调两腿。等待预热或退避的路线让出盘口采样容量。

## 验收条件

- [x] 通过正式扫描入口和原生 worker 观察不同步预热。记录两腿各自预热完成、盘口请求及实际采样时刻，对比快腿提前采样和双腿时差超限的情况。
- [x] 记录慢来源或退避期间仍可服务的路线继续采样并发布机会。预热与采样均遵守现有 worker 容量和 Venue 并发约束。
- [x] worker 轮转、目录或 InstrumentRules 变更后，只有当前绑定且通过预热校验的 worker 可采样。失效的在途结果不能恢复旧机会。

## Answer

盘口 worker 先完成原生元数据校验和订阅，规则到期或捕获会话轮转时重新校验。路线的两腿都就绪后才申请盘口额度。公共 transport 在同一把限频锁下为双腿确定共同起始时刻。遇到长间隔或退避时推迟整条路线，其他可服务路线仍可派发。目录、绑定变化及晚到响应沿用来源 generation 校验。

### 离线验收

Windows 使用已有的 `ringwin-scanner-market.exe`，通过 `ScannerRuntime.step`、原生 worker 和扫描候选快照观测。相同的合成 OKX／Hyperliquid 负载包含两条路线，`TOKEN0` 的 OKX 预热响应额外延迟 3.6 秒。基线为 `7e30b2b6`。下表为启扫后的毫秒数，采样时刻取原生规范深度的 `visible_at_ns`。

| 实现 | 路线 | 盘口腿 | 原生预热完成 | 首次实际请求 | 首次实际采样 |
| --- | --- | --- | ---: | ---: | ---: |
| 基线 | TOKEN0 | OKX | 4219 | 4219 | 4219 |
| 基线 | TOKEN0 | Hyperliquid | 1407 | 2313 | 2313 |
| 基线 | TOKEN1 | OKX | 532 | 532 | 532 |
| 基线 | TOKEN1 | Hyperliquid | 1438 | 2438 | 2438 |
| 本票 | TOKEN0 | OKX | 5313 | 5688 | 5688 |
| 本票 | TOKEN0 | Hyperliquid | 1735 | 5688 | 5688 |
| 本票 | TOKEN1 | OKX | 1797 | 3110 | 3110 |
| 本票 | TOKEN1 | Hyperliquid | 1625 | 3110 | 3110 |

- 两条路线首对样本的时差均从 1906 ms 降至 0 ms，超 1 秒的路线从 2 条降至 0 条。本票的 TOKEN1 在 3813 ms 发布可计算价差的候选，早于 TOKEN0 慢腿在 5313 ms 就绪。TOKEN0 在 6297 ms 发布候选，基线为 5391 ms。工作区原始记录见 `.scratch/build/scanner-paired-01-trace.jsonl`。
- `python python/verify_scanner_capacity.py --selected 16 --seconds 30 --rounds 1` 完成 8 条路线首轮，耗时 7.125 s。9 组双腿样本的时差 P95/P99 均为 16 ms，峰值 16 个活动 worker。广域慢来源用例验证其他路线持续发布，并检查 worker 上限。限频用例验证 Hyperliquid 的 429 不占用 OKX 额度，扫描集成用例验证退避和元数据限频期间两腿均不请求盘口。
- 定向原生集成回归覆盖规则变更使在途预热失效、设置切换丢弃旧盘口、捕获预算轮转重新预热、候选发布和原文重放。共 7 项定向用例通过。
