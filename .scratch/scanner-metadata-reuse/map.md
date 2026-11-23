# 机会扫描器的全市场元数据复用

Status: closed

## Destination

减少同源 worker 轮转时重复下载全市场元数据的成本，并量化对预热和扫描覆盖的影响。依据[优化方向一](../机会扫描器优化.md)和[离线容量基线](../../docs/research/2026-11-22-scanner-capacity.md)。

## Definition of done

三张工单各有可复核的完成证据。16、64、256 盘口的离线前后对照列出实际元数据请求量、worker 预热耗时、首轮耗时和新鲜覆盖率。规则变更、断线恢复、刷新失败和 429 的定向验收通过。

## Rules

- 通过正式扫描入口和原生 worker 验收。复用以实际公共行情来源及响应适用范围为界，每个 Instrument 继续通过原生身份与版本校验。
- 保留 5 秒盘口时效、1 秒双腿采样时差、行情不健康时撤回机会以及批准时的有效期复核。
- 按直接阻塞关系认领一张 Frontier 工单。完成后记录证据并更新工单状态、Frontier 和 Decisions so far。

## Route

| 工单 | 直接阻塞票 |
| --- | --- |
| [01 建立 worker 预热基线](issues/01-warmup-baseline.md) | 无 |
| [02 让轮转 worker 安全复用同源全市场元数据](issues/02-reuse-market-metadata.md) | 无 |
| [03 验证三档负载下的收益和机会有效性](issues/03-verify-capacity-and-freshness.md) | [01](issues/01-warmup-baseline.md)、[02](issues/02-reuse-market-metadata.md) |

## Frontier

三张工单均已完成。

## Decisions so far

用户已确认三张工单及阻塞关系。01 可以从复用前的版本获取基线，02 可以独立完成复用与失效验收。03 在两者完成后做同口径对照。

[01 的离线基线](issues/01-warmup-baseline.md#首轮实测)已封存。03 沿用同一容量脚本、原生 worker 启动方式和采样口径，按实际 HTTP 请求对照目录发现、worker 预热和刷新，并分别比较初开与重开时长。

[02 的定向验收](issues/02-reuse-market-metadata.md#实现与验证)通过。Hyperliquid 标准永续元数据自实际响应返回起复用 5 秒，每个原生 worker 仍重验自己的 Instrument 和规则版本。OKX 单品种响应按品种隔离。

[03 的离线同口径复测](issues/03-verify-capacity-and-freshness.md#离线容量对照)中，16、64、256 盘口的 Hyperliquid worker 预热请求从 7、44、104 次降至 1、5、21 次。正式扫描和批准入口通过规则变更、5 秒时效、1 秒双腿时差和行情健康度的定向验收。

## Not yet specified

无。

## Out of scope

方向二的双腿调度、方向三的批量报价与流式深度、实盘交易和生产资格。
