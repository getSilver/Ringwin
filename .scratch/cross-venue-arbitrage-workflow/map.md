# 跨所价差套利从扫描到交易

Status: open

## Destination

用户在前端选择两腿市场并扫描机会，人工批准具体路线后由策略开仓、管理敞口、退出及对账。[来源需求](../../docs/research/2026-11-19-cross-venue-arbitrage-workflow.md)

## Definition of done

15 张票逐项附上对应验收证据。首个交易里程碑为双 IOC 正常周期，随后验收异常恢复、Maker 周期及广域扫描容量。

## Rules

按直接阻塞关系认领可开工票。完成票据时更新证据、状态与 Frontier；验收记录注明实际场所、环境和数据来源。

## Route

| 票据 | 直接阻塞票 |
|---|---|
| [01 从空配置保存并启动扫描范围](issues/01-scope.md) | 无 |
| [02 用核心资产投影识别两腿敞口](issues/02-assets.md) | 无 |
| [03 按用户选择生成跨产品、跨环境候选](issues/03-pairing.md) | 01、02 |
| [04 手动费率贯穿扫描和开仓复核](issues/04-fees.md) | 无 |
| [05 USDT/USDC 平价估值与汇差归因](issues/05-stablecoin.md) | 无 |
| [06 在机会页给出可复算的交易潜力](issues/06-evaluation.md) | 03、04 |
| [07 跨所策略以空交易名单启动](issues/07-empty-list.md) | 无 |
| [08 从机会页将一条路线加入指定策略](issues/08-approve.md) | 06、07 |
| [09 从策略页查询和撤销持久批准](issues/09-revoke.md) | 07 |
| [10 让策略限价准确到达 Gateway](issues/10-limit-price.md) | 无 |
| [11 从前端批准跑通双 IOC 完整周期](issues/11-dual-ioc.md) | 05、08、10 |
| [12 双 IOC 单腿失败与重启恢复](issues/12-ioc-recovery.md) | 11 |
| [13 Maker 撤换单、增量对冲与恢复](issues/13-maker.md) | 11 |
| [14 扩大扫描范围并展示实际覆盖](issues/14-coverage.md) | 03 |
| [15 滚动归档并测出持续扫描容量](issues/15-capacity.md) | 14 |

## Frontier

- [03 按用户选择生成跨产品、跨环境候选](issues/03-pairing.md)
- [04 手动费率贯穿扫描和开仓复核](issues/04-fees.md)
- [05 USDT/USDC 平价估值与汇差归因](issues/05-stablecoin.md)
- [07 跨所策略以空交易名单启动](issues/07-empty-list.md)
- [10 让策略限价准确到达 Gateway](issues/10-limit-price.md)

## Decisions so far

用户已确认本图 15 张票及依赖。双 IOC 故障恢复与 Maker 共用正常交易周期；广域扫描独立验收。稳定币估值与原币账务的 ADR 调整归 05。

[01](issues/01-scope.md) 已通过正式设置页离线验收，应用范围可跨会话和重启恢复。第三注册来源由合成协议数据验证。

扫描节点通过现有只读核心投影读取生效资产登记。候选和归档证据引用当时的登记版本，验收范围见 [02](issues/02-assets.md)。

## Not yet specified

以分级负载测量确定持续覆盖规模和延迟目标。

## Out of scope

本图记录跨所套利业务交付和运行证据；生产发布和实盘授权另行管理。
