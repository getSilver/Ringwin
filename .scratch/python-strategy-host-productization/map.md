# 产品化接入 Python StrategyHost

Label: wayfinder:map
Status: resolved

## Notes

- 本地图经 SystemOwner 选择，继续把执行工作纳入路线；每次只认领并完成一张 frontier。
- 实现遵循 Ponytail：优先复用当前 `TradingShard`、稳定事件编码、Zig/Python 标准库和
  已验证的 throwaway prototype 契约；不引入通用 RPC、插件框架或第三方消息总线。
- 历史 Python Host 原型只提供业务证据，不能复制其 Python `RawValue` ring 作为产品 IPC。
- Python 策略属于中低频高延迟等级，不进入原生核心 10 us 合同，也不得阻塞 TradingShard。

## Destination

在现有确定性 Zig 交易引擎外围接入可执行的 Python StrategyHost 产品能力：
四个独立 Host 各承载约 25 个中低频 StrategyInstance，通过产品级有界本机 IPC
接收版本化事件批次并返回 OrderIntent；TradingShard 重新验证身份、schema、游标、
新鲜度和交易授权后，仍走同一个定点风险、订单、日志与重放核心。

最终演示必须证明约 100 个策略的正常决策、单策略异常隔离、单 Host 崩溃/卡死隔离、
输入落后、输出通道填满、旧会话迟到、checkpoint 损坏及 checkpoint + 决策日志追赶恢复；
恢复期间不得产生交易意图，恢复后游标和确定性策略状态必须闭合。

## Inherited contracts

- 四个独立 StrategyHost，每个约 25 个策略；Host 故障不能阻塞其他 Host 或 TradingShard。
- 核心到 Host 与 Host 到核心使用两条 Zig 拥有原子游标的有界 SPSC 通道。
- 输入批次连续标识 HostBatchSequence 与首末 ShardSequence；未知 schema、CRC 错误、
  序号缺口或旧 HostSessionIdentity 失败关闭。
- Host 取批时批次年龄超过 50 ms 进入 NeedsSnapshot，不调用策略。
- OrderIntent 返回时批次年龄超过 100 ms，TradingShard 以 stale intent 拒绝，
  不进入风控或 OMS。
- PythonDecisionLatency 报告 P50/P99/P99.9/Max；合同为 P99 <= 50 ms、
  P99.9 <= 100 ms，独立于 CoreDecisionLatency。
- checkpoint 只允许显式稳定 schema 的 PortableStrategyState；禁止 pickle、marshal、
  Python 对象图或解释器快照。
- 恢复先加载已确认 checkpoint，再在无交易权限模式下重放缺失事件，追赶到核心屏障后
  才恢复交易；不能用最新行情快照伪造策略私有状态。
- 普通 Python 异常只停用对应 StrategyInstance；不可抢占卡死由外围 supervisor
  终止并重建整个 Host。

## Route

- [冻结 StrategyHost 产品 seam 与验收轨迹](issues/01-freeze-product-contract.md)
- [实现 Zig 拥有的共享内存 IPC](issues/02-implement-zig-owned-ipc.md)
- [实现 Host 握手、会话与进程生命周期](issues/03-host-session-lifecycle.md)
- [把批事件与 OrderIntent 接入 TradingShard](issues/04-integrate-trading-shard.md)
- [实现 checkpoint、日志追赶与恢复屏障](issues/05-checkpoint-replay-recovery.md)
- [实现异常、卡死、崩溃与过载失败轨迹](issues/06-failure-and-overload.md)
- [验证四 Host、约百策略的容量与延迟](issues/07-capacity-and-latency.md)
- [形成可复现演示并关闭 Python 能力波次](issues/08-close-python-wave.md)

## Decisions so far

- [形成可复现演示并关闭 Python 能力波次](issues/08-close-python-wave.md)
  已形成一条跨平台、失败即停的 14 项自动验收入口并在当前 Windows 环境完整通过；
  README 固化权威状态边界和未资格事项。下一能力波次选择 OKX Venue Adapter
  最小纵向接入，Linux 专用核心性能资格继续独立处理。
- [验证四 Host、约百策略的容量与延迟](issues/07-capacity-and-latency.md)
  已用产品 SPSC seam 在五种场景各采集至少 100 万决策样本；Windows 上 Python
  延迟合同与 Host 隔离通过，Linux 目标可交叉构建。2C/4T Windows 节点无法满足
  四分片专用核部署条件，核心并发资格明确未通过，留待合格 Linux 节点复核。
- [实现异常、卡死、崩溃与过载失败轨迹](issues/06-failure-and-overload.md)
  已实现单策略事务式异常隔离、Host 级 RecoveryRequired 失败关闭、crash/hang
  新 session 重建、输出满与输入损坏栅栏、checkpoint 回退及跨 session intent 去重；
  四个真实 Host 的矩阵证明健康 cursor 连续且无重复或旁路订单。
- [实现 checkpoint、日志追赶与恢复屏障](issues/05-checkpoint-replay-recovery.md)
  已实现受 CRC/hash/显式 schema 约束的 PortableStrategyState checkpoint、按批次
  覆盖连续的无权日志追赶、StrategyStateDigest 核对和 activation 栅栏；真实 Python
  Host 恢复期间零输出，核心也拒绝提前 intent，恢复后身份与独立重放一致。
- [把批事件与 OrderIntent 接入 TradingShard](issues/04-integrate-trading-shard.md)
  已实现订阅并集过滤和稳定批次、真实 Python 共享内存往返、冻结 `OrderIntentV1`，
  并让 Python 与原生 intent 共用同一个 TradingShard 定点风控、订单、日志和重放入口；
  七类身份、游标、schema、授权和时效失败均稳定拒绝且不进入风控。
- [实现 Host 握手、会话与进程生命周期](issues/03-host-session-lifecycle.md)
  已实现四 Host 控制 pipe、精确 Compatibility、ReadyForRecovery、启动/心跳/停止
  超时、crash/hang 后新 generation 重建，以及旧 session 三类输出 fencing。
- [实现 Zig 拥有的共享内存 IPC](issues/02-implement-zig-owned-ipc.md)
  已实现 Windows 匿名 File Mapping、Linux 匿名 `memfd`、两条 acquire/release
  SPSC、冻结 cdecl ABI 和失败关闭校验；父子进程双向传输、wrap、满/空、CRC、
  旧会话及 Python `ctypes` ABI 已有可运行证据。
- [冻结 StrategyHost 产品 seam 与验收轨迹](issues/01-freeze-product-contract.md)
  已冻结一分片一 Host 的所有权、最小 Zig C ABI、稳定输入/输出/checkpoint/control
  schema、activation fencing、确定性恢复和完整成功/失败验收轨迹。
- [确定原生与 Python 策略执行模型](../quant-trading-system/issues/04-strategy-execution-and-deployment.md)
  已确定 Python 运行在独立 Host 进程，经共享内存批量接收事件并返回 OrderIntent。
- [原型验证 Python Strategy Host](../quant-trading-system/issues/22-prototype-python-strategy-host.md)
  已证明 4 Host/100 策略的容量量级、Host 落后隔离及 checkpoint + replay 语义可行，
  但 Python RawValue 内存序不能进入产品。
- [定义可观测性与性能验收契约](../quant-trading-system/issues/23-observability-and-benchmark-contract.md)
  已冻结 50/100 ms Python 延迟合同、完整分布和 stale/NeedsSnapshot 边界。

## Frontier

无；本地图已完成。下一能力波次为 **OKX Venue Adapter 最小纵向接入**，
后续以独立地图认领，不在本地图追加实现。

## Reused evidence

- [现有交易引擎闭环](../quant-trading-engine-vertical-slice/map.md)
- [Python Strategy Host throwaway prototype](../quant-trading-system/prototypes/python-strategy-host/README.md)
- [事件 taxonomy 与 StrategyHost IPC 契约](../quant-trading-system/issues/29-event-taxonomy-and-schema-compatibility.md)
- [状态迁移与 PortableStrategyState](../quant-trading-system/issues/25-state-migration-and-rollback.md)
- [核心领域词汇与不变量](../../CONTEXT.md)

## Out of scope

- 真实 OKX、Binance、Gate.io 或 Bitget Adapter、testnet 或生产下单。
- 修改原生 Zig 策略的静态编译模型或 10 us 核心延迟合同。
- 把 Python 嵌入 TradingShard 进程、让 Python 持有权威订单/仓位/账本状态，
  或让 Python 绕过定点风险和 OMS。
- 不可信多租户安全沙箱；首版策略代码属于受信任部署物，但其故障仍受进程边界隔离。
- 通用语言插件 SDK、远程 StrategyHost、网络 RPC、容器编排和 Kubernetes。
- NumPy/机器学习框架的统一运行时；容量票使用代表性标准库策略，真实策略需要时再增加依赖。
- Linux 五核核心交易资格和真实 Venue 网络延迟；Python 产品路径最终仍需在约定 Linux
  节点复核自身 50/100 ms 合同。
