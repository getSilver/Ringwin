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

- [12 双 IOC 单腿失败与重启恢复](issues/12-ioc-recovery.md)
- [13 Maker 撤换单、增量对冲与恢复](issues/13-maker.md)
- [15 滚动归档并测出持续扫描容量](issues/15-capacity.md)

## Decisions so far

用户已确认本图 15 张票及依赖。双 IOC 故障恢复与 Maker 共用正常交易周期；广域扫描独立验收。稳定币估值与原币账务的 ADR 调整归 05。

[01](issues/01-scope.md) 已通过正式设置页离线验收，应用范围可跨会话和重启恢复。第三注册来源由合成协议数据验证。

扫描节点通过现有只读核心投影读取生效资产登记。候选和归档证据引用当时的登记版本，验收范围见 [02](issues/02-assets.md)。

[03](issues/03-pairing.md) 按核心登记资产匹配跨环境路线，为全部产品搭配生成两个方向并逐腿记录行情来源与缺项。广域轮转和实际覆盖由 [14](issues/14-coverage.md) 验证。

[04](issues/04-fees.md) 以离线费率保存、扫描重算、历史重放及策略开仓复核证据关闭，解除 [06](issues/06-evaluation.md) 的阻塞。正式 StrategyHost 费率接线和开仓验收由 [11](issues/11-dual-ioc.md) 承接，使用 [08](issues/08-approve.md) 提供的账户绑定。

[06](issues/06-evaluation.md) 已通过同结算币离线验收，覆盖固定金额净边际、逐腿行情年龄、材料缺失撤回及归档复算。

[05](issues/05-stablecoin.md) 已完成扫描平价、核心混合结算币批准及实际周期汇差的离线验收。核心已提交账务和汇率引用可恢复重算。正式双 IOC 运行验收见 [11](issues/11-dual-ioc.md)。

[07](issues/07-empty-list.md) 已通过空名单、存量敞口及正式 Linux 联合验收。默认 Web 从 Writer 读取名单，正式 engine 恢复 Venue 输入，StrategyHost 从 checkpoint 追平并确认核心提交序号。双 IOC 正常交易周期及单腿失败恢复分别由 [11](issues/11-dual-ioc.md) 和 [12](issues/12-ioc-recovery.md) 接续。

[08](issues/08-approve.md) 已通过合成 Demo × Testnet 的认证 Web、Zig Writer 和恢复定向验收。机会批准绑定显示的评估和指定组合，核心回执可独立核对观察来源与部署账户。完整交易周期由 [11](issues/11-dual-ioc.md) 接续。

[09](issues/09-revoke.md) 已通过策略页持久身份、停扫和 Web 重启、失效批准、丢回执及历史满载撤销的离线定向验收。Writer 提交撤销后立即限制新开仓。

[10](issues/10-limit-price.md) 已通过 Host 限价定向验收。Gateway 请求保留各腿 ticks 和规则版本，TradingShard 校验 tick 单位并逐腿记录拒绝原因。

[11](issues/11-dual-ioc.md) 已在远端 Linux 完成批准评估交付、独立 Gateway 进程分派、两腿开平仓和原币与汇差对账的模拟场所验收。

[12](issues/12-ioc-recovery.md) 已验证模拟场所单腿部分成交、另一腿 Unknown 后拒绝时的持久恢复、单笔减仓和费用归档。正式 Host 周期投影与独立 Gateway 查询接线待完成。

[14](issues/14-coverage.md) 已用 20 个盘口、10 条路线完成离线双腿轮转验收。持续归档和容量测量由 [15](issues/15-capacity.md) 接续。

## Not yet specified

以分级负载测量确定持续覆盖规模和延迟目标。

## Out of scope

本图记录跨所套利业务交付和运行证据；生产发布和实盘授权另行管理。
