# Python Strategy Host 原型

> Throwaway prototype：验证跨进程协议和恢复语义，不是生产 IPC 实现。

## 问题

四个相互隔离的 Python Strategy Host 各运行 25 个中低频策略时，共享内存批处理、Host 内订阅合并、连续批次序号、策略状态 checkpoint + 事件重放，以及共享内存返回 `OrderIntent`，能否让单 Host 落后不阻塞 TradingShard 或其余 Host，并最终恢复到相同游标？

原型使用 Python 标准库固定槽位 SPSC ring。默认每个 Host 接收 1,000 batches/s、每批 32 个市场更新，持续 8 秒；自动暂停一个 Host 250 ms。序号不连续或批次年龄超过 50 ms 都会使 Host 停止产生意图并进入恢复。

## 一条命令

```powershell
python .scratch/quant-trading-system/prototypes/python-strategy-host/main.py
```

手工观察状态机：

```powershell
python .scratch/quant-trading-system/prototypes/python-strategy-host/main.py --demo
```

`NeedsSnapshot` 不能只靠最新市场快照恢复任意策略内部状态。候选契约要求恢复已确认的策略状态 checkpoint，在禁止产生订单意图的恢复模式下重放缺失事件，到序号屏障后才恢复交易。

原型依赖 Python `RawValue` 在本机 x86-64 上传递 SPSC 游标，但没有证明跨平台内存序；生产 Zig/Python 共享内存必须使用 Zig 侧 acquire/release 原子游标并进行 Linux 压测。

## 2026-07-27 本机结果

Windows、Python 3.9.18，四轮默认负载：

| 指标 | 结果 |
| --- | ---: |
| Host / 策略 | 4 / 100 |
| 运行负载 | 每 Host 1,000 batches/s × 32 updates，持续 8 s |
| 策略投递 | 3,200,000，约 399,800/s |
| 合并后的市场事件复制 | 128/batch，未合并为 400/batch，减少 68% |
| `OrderIntent` 往返 P50 | 2.11 ms 中位 |
| `OrderIntent` 往返 P99 | 4.97 ms 中位，最差一轮 37.16 ms |
| 落后 Host | 每轮恰好恢复一次，最终游标 8,000 |
| 其他 Host | 0 丢批、0 恢复，最终游标 8,000 |

每轮返回 7,825 个 `OrderIntent`。理论正常运行会产生 8,000 个；恢复重放期间安全抑制了 175 个过期意图，没有迟发，也没有重复身份。

生产实现不照搬本原型的 Python ring 类。候选 seam 是两条由 Zig 拥有原子游标的有界 SPSC 通道：核心到 Host 的批事件通道允许因落后而失效并触发恢复；Host 到核心的 `OrderIntent` 通道不得静默丢弃，填满时 Host 失败关闭。
