# 原型验证 Python Strategy Host

Type: prototype
Status: resolved
Blocked by: 13, 19
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

共享内存批处理协议、进程隔离、订阅合并、落后检测、快照重同步和 OrderIntent 返回能否让约 100 个 Python 中低频策略稳定运行？

## Answer

原型位于[Python Strategy Host 原型](../prototypes/python-strategy-host/README.md)，仅使用 Python 标准库。实验采用四个独立 Host 进程，每个承载 25 个 StrategyInstance，并与四个 TradingShard/DecisionDomain 的所有权形态对齐。每个 Host 内先合并策略订阅，再将一个市场更新分派给订阅它的策略；Host 是故障与延迟隔离单位，单策略无限循环等不可抢占故障仍可能使同 Host 的 25 个策略一起重启，但不能阻塞 TradingShard 或其他 Host。

候选 module interface 只有两条有界 SPSC 通道和一组控制状态：

- TradingShard → Strategy Host：版本化批事件、batch sequence、单调发送时间和恢复控制记录。TradingShard 永不等待 Python。
- Strategy Host → TradingShard：不可变 `OrderIntent`、checkpoint 和恢复请求。`OrderIntent` 通道不得静默丢弃，容量耗尽时 Host 失败关闭。
- Python 进程只产生不受信任的 `OrderIntent`；TradingShard 仍须验证 StrategyInstance、VirtualPortfolio、ExchangeAccount、配置版本、游标新鲜度及 RiskLease，不接受 Python 直接形成 OrderCommand。

落后由两个独立条件判定：batch sequence 不连续，或批次年龄超过配置的最大值；原型采用 50 ms。任一条件成立即停止策略交易权限并进入 `NeedsSnapshot`，不能继续处理 ring 中虽然连续但已经过期的行情。

恢复不能只发送最新 MarketView。任意 Python 策略可能拥有指标、定时器及模型状态，市场快照不能重建这些私有状态。候选恢复协议是：

1. Host 在已处理 batch sequence 屏障导出全部策略状态 checkpoint。
2. `NeedsSnapshot` 后丢弃未确认输入，恢复最近已确认 checkpoint。
3. 从分片决策日志重放 checkpoint 后的事件；状态为 `Recovering`，禁止产生 `OrderIntent`，避免迟发或重复交易。
4. 到达核心给定的当前序号屏障并核对所有策略游标后切回 `Active`。
5. checkpoint 不可恢复、事件日志不再覆盖缺口、schema/策略版本不匹配时保持失败关闭，必须重新 warm-up 或由 SystemOwner 停用。

策略产生的意图身份必须由 StrategyInstance、策略决策序号及意图序号确定性构成；核心对重复身份幂等拒绝。即使未来允许恢复重放产生意图，也不能依赖进程内随机 UUID 避免重复。当前候选更保守：恢复重放一律更新状态但抑制交易意图。

本机使用 Windows、Python 3.9.18，按每 Host 1,000 batches/s、每批 32 个市场更新、持续 8 秒运行四轮，并在第 2 秒暂停 Host 0 达 250 ms：

| 指标 | 结果 |
| --- | ---: |
| Host / StrategyInstance | 4 / 100 |
| 策略投递 | 每轮 3,200,000，约 399,800/s |
| 订阅合并后的事件复制 | 128/batch；逐策略复制为 400/batch，减少 68% |
| `OrderIntent` 往返 P50 | 2.11 ms 中位 |
| `OrderIntent` 往返 P99 | 4.97 ms 中位；最差一轮 37.16 ms |
| Host 0 | 每轮恰好一次落后恢复，最终 `Active`、cursor 8,000 |
| Host 1–3 | 0 丢批、0 恢复，最终 `Active`、cursor 8,000 |

每轮正常理论值为 8,000 个意图，实际返回 7,825 个；175 个落在恢复区间的过期意图被安全抑制。没有重复意图身份。这个结果符合已经接受的 Python 中低频高延迟等级，并证明一个 Host 落后不会把背压传入 TradingShard。

初步结论：约 100 个中低频策略可以采用四个 Strategy Host、每个约 25 个策略的形态；共享内存只作为批事件与意图传输 seam，订阅路由、游标、checkpoint 和重放语义由 Host module 隐藏。普通 Python 异常应只停用对应 StrategyInstance；不可抢占的阻塞由外部 supervisor 杀死并重建整个 Host。

这不是生产 IPC 或策略容量验收。Python `RawValue` 没有为候选 Zig/Python ABI 证明 acquire/release 内存序；原型策略只是确定性计数器，也没有覆盖 NumPy、模型推理、GC 峰值、真实订阅倾斜、四个 Host 的 CPU 亲和性或 Host 崩溃重启。Debian 13/Zig 0.17/Python 正式版本上的生产准入必须使用 Zig 拥有的原子 ring，测试真实策略样本、异常/死循环/进程崩溃、输出通道填满、checkpoint 损坏和日志保留不足，并测量各延迟等级的 P99/P99.9。

确认采用四个 Strategy Host、每个约 25 个 Python 中低频策略的候选方案，以及双 SPSC 通道、订阅合并、序号与时效双重落后检测、StrategyCheckpoint + 日志重放和恢复期抑制意图的契约。Zig 原子内存序、真实策略负载、Host 崩溃与输出通道过载测试继续作为生产准入条件，不由本原型结果豁免。
