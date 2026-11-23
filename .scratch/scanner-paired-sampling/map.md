# 机会扫描器双腿采样对齐

Status: closed

## Destination

减少 worker 预热与限频排队造成的双腿采样时差，在请求完成或额度可用时及时推进扫描。依据[优化方向二](../机会扫描器优化.md#方向二--对齐双腿采样减少时差超限和空等)。

## Definition of done

四张工单均有可复核的离线验收证据。经正式扫描入口和原生 worker 复测 16、64、256 盘口，量化双腿时差超限、重试、路线等待、首轮耗时和新鲜覆盖率。共享盘口、不同步预热、慢来源和 429 下的推进与公平性均有运行证据。

## Rules

- 盘口时效为 5 秒，双腿采样时差最多 1 秒。行情不健康时撤回受影响机会，批准时由服务端复核有效期。
- 沿用原生 Instrument 和 InstrumentRules 校验、实际行情来源的限频与每 Venue 并发上限。复用盘口时保留原采样时刻和 RawIngress 证据。
- 沿用现有离线验收入口和夹具。每次认领一张 Frontier 工单，完成后登记验收证据并更新地图。

## Route

| 工单 | 直接阻塞票 |
| --- | --- |
| [01 双腿就绪后协调采样](issues/01-coordinate-ready-legs.md) | 无 |
| [02 由请求完成和限频窗口推动扫描](issues/02-wake-on-completion-and-budget.md) | [01](issues/01-coordinate-ready-legs.md) |
| [03 复用共享盘口并验证公平轮转](issues/03-reuse-shared-books-and-rotate-fairly.md) | [01](issues/01-coordinate-ready-legs.md) |
| [04 复测三档容量与机会有效性](issues/04-verify-capacity-and-eligibility.md) | [02](issues/02-wake-on-completion-and-budget.md)、[03](issues/03-reuse-shared-books-and-rotate-fairly.md) |

## Frontier

四张工单均已完成。

## Decisions so far

- 用户已确认四张工单及直接阻塞关系。02 和 03 都以 01 的采样就绪边界为基础。03 可用现有定时推进独立验收，04 复测合并后的行为。
- 前后对照以[元数据复用已落地的版本](../scanner-metadata-reuse/map.md)为基线，沿用[离线容量报告](../../docs/research/2026-11-22-scanner-capacity.md)的负载与覆盖口径。缺少的新指标用同一测量方法补测。

- 01 已验收。双腿完成原生校验后从实际公共来源限频预算取得同一批盘口额度，慢预热与退避期间继续服务其他就绪路线。前后对照时刻和定向验收见 [01](issues/01-coordinate-ready-legs.md#离线验收)。
- 02 已验收。正式自动循环在请求完成或额度开放时推进扫描，目录与盘口共用 Venue 并发额度，维护周期继续处理过期和刷新。调度时刻和慢响应、429 下的观测见 [02](issues/02-wake-on-completion-and-budget.md#离线验收)。
- 03 已验收。两条共享路线首次同时新鲜前的实际盘口请求从 10 次降至 7 次。原文回放确认复用保留采样时刻和 RawIngress 引用，持续高边际报价下的低优先级路线首次及 429 恢复后的可服务等待分别为 469 ms 和 1000 ms，均在 14 秒夹具上界内。见 [03](issues/03-reuse-shared-books-and-rotate-fairly.md#离线验收)。

- 04 已验收。三档均完成首轮，对照版 170 组样本均满足 1 秒时差限制，时差重试由 27 次降为 0。16 盘口首轮缩短，64 和 256 盘口首轮延长，256 盘口从 119.329 秒增至 184.875 秒。覆盖率缺测、故障注入和批准入口的验收记录见 [04](issues/04-verify-capacity-and-eligibility.md)。

## Not yet specified

无。

## Out of scope

方向一的元数据复用改造、方向三的批量报价与流式深度改造、实盘交易和生产资格。
