# 修复交易核心权威接缝与验收完整性

Label: wayfinder:map
Status: in_progress

## Destination

修复当前源码与既有“交易核心已闭环”结论之间的偏差：让账户观察、市场连续性、Instrument 配置、
Execution Gateway 和 CanonicalEvent 只保留一个权威演进路径；让 OKX、Binance、Bybit 经相同
VenueAdapter seam 完成可重放闭环；并以不可伪造、可重复的自动验收重新建立当前完成度基线。

本地图是针对当前源码缺口的新修复波次。既有 resolved/closed ticket 作为历史审计记录保留，不能
替代本地图要求的当前实现证据。

## Definition of done

- AccountProjection 的 gap、冲突和容量失败会形成可重放的失效事实并收紧 EffectiveTradingAuthority，
  不会被 TradingShard 的候选状态事务回滚吞掉。
- MarketProjection 与 SafetyGate 对 gap 和完整快照恢复只有一条权威路径；未跟踪的 Instrument 不会
  绕过 fail-closed 行为。
- 同一 TradingShard 能以规范 InstrumentIdentity 同时闭合 SPOT 与 isolated linear USDT 永续的风险、
  OMS、成交、经济投影、快照和 replay，且不依赖特殊数值常量解释产品类型。
- Account 唯一所有者经一个 Execution Gateway 把 OrderCommand 路由到 VenueAdapter，并把规范事实
  返回 TradingShard；历史重放没有发送能力，受限模式仍允许安全撤单、reduce-only 和 reconciliation。
- OKX、Binance、Bybit 使用相同执行与行情契约；一个 Venue 的失败不会污染其他 Venue。
- 离线构造的布尔值或摘要不能形成 TestnetQualified；资格结论必须与实际运行证据等级一致。
- StrategyHost 容量场景在不放宽既定时效边界的情况下稳定通过或给出确定、可定位的失败证据。
- CoreInput 兼容包装和重复影子状态经 expand-contract 迁移后删除，每类 AuthoritativeTradingState
  只有一个权威来源。
- 完整 core wave 从实际运行中报告 schema、测试数、barrier 和 digest，当前状态文档与活动 tracker
  不再引用已经失真的旧基线。

## Rules

- 每次只认领并完成一张 Frontier ticket；只声明真正阻止实现开始的依赖。
- 延续 single-context 和深模块边界；Venue 私有协议不得进入 TradingShard、日志或 replay。
- 账户执行使用绑定 Venue、Environment、ExchangeAccount 的 VenueAdapter；公共行情使用可共享的
  MarketFeedAdapter；两者只向核心输出 CanonicalEvent。
- 修复根因及公共 seam，不为单个调用点添加旁路，不创建第二套核心或通用插件框架。
- 所有失败路径必须 fail-closed；不能为了让验收通过而放宽风险、新鲜度、幂等或时序合同。
- 只更新仍作为当前入口的状态文档和 tracker 索引；历史 resolved/closed ticket 内容不批量改写。
- 不同步 GitHub Issues，除非用户另行明确要求。

## Route

- [提交 AccountProjection 的失效事实](issues/01-commit-account-projection-failure.md)
- [统一市场连续性与恢复权威](issues/02-unify-market-continuity-authority.md)
- [将单一 Instrument 配置扩展为有界注册表](issues/03-expand-bounded-instrument-registry.md)
- [在同一 TradingShard 完成 SPOT 与线性合约闭环](issues/04-close-multi-instrument-trading-loop.md)
- [收敛为唯一 Execution Gateway](issues/05-unify-execution-gateway.md)
- [让 Binance 通过统一 Gateway 完成端到端路径](issues/06-route-binance-through-gateway.md)
- [让 Bybit 通过统一 Gateway 完成端到端路径](issues/07-route-bybit-through-gateway.md)
- [使 Testnet 资格证据不可自行声明](issues/08-make-testnet-evidence-authoritative.md)
- [修复 StrategyHost 容量验收的不稳定性](issues/09-stabilize-strategy-host-capacity.md)
- [扩展 typed CanonicalEvent 迁移入口](issues/10-expand-typed-canonical-event.md)
- [删除 CoreInput 包装与重复影子状态](issues/11-contract-legacy-core-input.md)
- [重建可信验收基线并校正文档](issues/12-rebuild-trusted-acceptance-baseline.md)

## Frontier

- [05: 收敛为唯一 Execution Gateway](issues/05-unify-execution-gateway.md)

## Decisions so far

- 2026-09-05：用户批准按 12 个 tracer-bullet ticket 修复当前源码审计发现；本地图新增修复证据，
  不把既有 closed map 的声明视为当前实现已通过。
- AccountProjection、MarketProjection、SafetyGate、Instrument 配置和 Gateway 的权威路径先于 Venue
  迁移；Binance 与 Bybit 在统一 Gateway 完成后可并行实施。
- CoreInput 使用 expand-contract：先增加 typed CanonicalEvent 入口并保持兼容，再迁移调用者并删除旧形态。
- Testnet runner 的实现和证据约束属于本波；缺少真实 opt-in 运行时必须诚实停在 ContractTested 或
  OfficialConfirmed，不能用合成数据代替 TestnetQualified。
- Windows 功能与容量回归、现有 Linux compile-only 属于开发闭环；生产 Linux 性能资格不属于本波。
- 2026-09-05：01–11 的实现与离线证据已落入本地图；11 已完成 contract 删除，12 已重建可信验收基线并关闭本波。
- 2026-09-05：复审后重新打开本波；01 修复了既有 failure 误提交无关失败事件、失败事实日志被 `errdefer` 回滚，以及 Gate/trace 错误被吞掉的问题，Debug/ReleaseSafe 179/179。
- 2026-09-05：02–04 复验并修复：MarketProjection 改为有界 per-Instrument 状态，Instrument 配置支持显式版本前进并拒绝冲突/倒退，SPOT/SWAP 风险与经济语义不再依赖特殊整数；schema 6 Debug/ReleaseSafe 180/180。
- 2026-09-05：最终离线证据为 schema 2、Debug/ReleaseSafe 各 178/178、coordinator barrier 17、
  shard barriers 23/26/21/21、Gateway 发送 4 次且 replay 无发送能力；共享摘要为
  `e124735e7c33b86358e0a9fe23d9d1a51a86436627821b7cfc48ffbfc7f23476`。OKX Demo、Binance Testnet、
  Bybit Testnet 均未在默认入口运行，未产生真实运行资格。

## Not yet specified

- 实际 Testnet 运行所使用的账户、时间窗口和网络条件；这些外部输入缺失时不阻塞证据模型修复，
  但不得产生 TestnetQualified 结论。
- 生产发布候选的 BenchmarkManifest、硬件基线和运维审批流程。

## Out of scope

- 生产账户和真实资金交易。
- 生产密钥托管、轮换、SecretMaterial 管理和权限运营。
- Linux 生产性能、CPU affinity、NUMA、io_uring、硬件时间戳和真实网络延迟资格。
- HA、PrimaryLease、外部 FencingToken、节点切换和生产部署。
- 新 Venue、SOR、动态插件框架、控制面 UI、研究数据平台、期权和组合保证金。
