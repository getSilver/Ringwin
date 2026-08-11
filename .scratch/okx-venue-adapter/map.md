# 产品化接入 OKX Venue Adapter

Label: wayfinder:map
Status: open

## Destination

交付一个接入现有确定性交易核心的 OKX Demo Trading 可执行纵向闭环：覆盖 BTC-USDT 现货与 BTC-USDT-SWAP 逐仓单向永续的公共行情、私有账户事实、既定完整订单能力、断线恢复与 REST 对账，并让真实 Demo 事实闭合订单、仓位、账本和重放投影。

自动验收只允许显式启用 Demo 环境，以固定白名单、名义金额上限、运行前对账、运行后撤单及 Reduce-only 清仓保护；不得连接生产账户、提交生产订单或使用真实资金。

## Notes

- 本地图经 SystemOwner 明确授权把执行工作纳入路线；每次只认领并完成一张 frontier，研究票可以并行。
- 每次会话使用 `wayfinder` 与 `ponytail`；涉及领域词汇、module interface 或 Zig 实现时补充 `domain-modeling`、`codebase-design` 与 `zig`，外部协议事实使用 `research`。
- Venue Adapter interface 是 TradingShard 与具体 Venue implementation 之间的唯一 seam；TradingShard 只产出规范 OrderCommand 并接收 CanonicalEvent，不接触 REST、WebSocket、签名或 OKX 字段。
- SimVenue 与 OKX Adapter 是该 seam 的两个真实 Adapter；不得为未来 Binance、Gate.io 或 Bitget 预建插件框架。
- 订单能力完整继承既有规格：Limit、Market、GTC、IOC、FOK、Post-only、VenueReduceOnly、原地 amend、获授权的 CancelConfirmCreate、非原子 TransportBatch、规范化、限流、稳定错误、Unknown 与 REST 对账。
- 继续禁用组合 cancel-replace、amend-failure 自动撤单、重叠式撤旧建新、静默能力降级及无界 Market 订单。
- Demo 凭证只从本机环境注入，不写入命令行、源码、票据、日志、测试制品或 Git；凭证必须无提现权限。
- 会成交的 Demo 验收必须显式 `--demo-live` 启用；任何环境、账户状态、对账或清理结果不确定时失败关闭。
- 最终验收必须由固定测试策略穿过 OrderIntent、规范化、定点风险、OrderCommand、OKX Adapter、Demo 回报、权威投影及重放；Adapter 单测不能单独关闭地图。
- 当前 Windows 节点完成离线、公共行情与 Demo 功能验收，并保持 `x86_64-linux-gnu` 可交叉构建；Linux 专用核心性能资格属于独立波次。
- 本地票据位于 [`issues/`](issues/)；`Status: open`、全部阻塞票已解决且无 Assignee 的最小编号非研究票是 frontier。

## Decisions so far

- [刷新 OKX API v5 与 Demo Trading 契约](issues/01-refresh-okx-v5-demo-contract.md) — OKX v5 可实现目标闭环，但须以版本化 endpoint/rules、序号连续性及 WS+REST Unknown 对账作为硬合同。
- [选择 Zig 0.17 OKX 传输基线](issues/02-choose-zig-transport-baseline.md) — 固定 libcurl 8.21.0 统一承载 HTTPS/WSS，单 owner 驱动取消与恢复边界。
- [冻结 Venue Adapter interface 与验收合同](issues/03-freeze-adapter-interface-and-acceptance.md) — 使用四操作、双向有界异步 seam 隔离 TradingShard 与 Venue I/O，并以 RawIngress 优先、分离就绪、失败关闭及五层轨迹验收。
- [资格化 Demo 账户与实盘式安全栅栏](issues/04-qualify-demo-account-and-safety.md) — Demo/global 专用 Key、Futures/net/isolated 配置与零遗留风险已通过只读资格；固定双 Instrument 白名单、25 USDT 单笔及账户总名义上限、显式 `--demo-live`、发送前对账和失败关闭清理合同。
- [建立 Venue Adapter seam 并保留 SimVenue](issues/05-establish-venue-adapter-seam.md) — 四操作运行时 seam 已落地，SimulatedVenue 通过容量 1 的无分配有界输出保留原权威轨迹、digest、重放与 Python StrategyHost 验收；未引入插件框架。

## Not yet specified

暂无；Demo 无法稳定制造的部分成交、传输 Unknown 与断线窗口由[证明断连、Unknown、部分成功与幂等恢复](issues/10-prove-failure-recovery-and-idempotency.md)选择可审计故障注入位置。

## Out of scope

- OKX 生产凭证、生产下单、真实资金和生产资格声明。
- Binance、Gate.io、Bitget 或通用多 Venue 插件框架。
- 币本位合约、双向持仓、组合保证金、统一跨币种抵押、期权、算法单和 SOR。
- 组合 cancel-replace、`cxlOnFail`、重叠式撤旧建新和通用条件订单工作流。
- 单活热备、fencing、生产部署、密钥托管系统和生产操作界面。
- Linux 专用核心、CPU affinity、NUMA、io_uring 与生产网络性能资格。

## Reused evidence

- [已完成的核心业务逻辑规格](../quant-trading-system/map.md)
- [选择首批生产交易所](../quant-trading-system/issues/14-choose-initial-venues.md)
- [建立交易所适配器能力契约](../quant-trading-system/issues/16-exchange-adapter-capabilities.md)
- [定义跨 Venue 订单能力降级语义](../quant-trading-system/issues/37-cross-venue-order-capability-degradation.md)
- [已完成的确定性交易引擎纵向闭环](../quant-trading-engine-vertical-slice/map.md)
- [已完成的 Python StrategyHost 产品化接入](../python-strategy-host-productization/map.md)
