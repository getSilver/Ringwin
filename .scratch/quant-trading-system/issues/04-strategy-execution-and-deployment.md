# 确定原生与 Python 策略执行模型

Type: grilling
Status: resolved
Blocked by: 02, 03
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

如何同时支持原生低延迟策略和 Python 中低频策略，并控制更新及故障影响？

## Answer

- 原生 Zig/C 策略静态编译到对应 TradingShard 进程，使用编译期注册，不在热路径动态加载。
- 原生策略只能读取标准化事件及只读市场视图、修改自己的状态并生成 OrderIntent。
- Python 中低频策略运行在独立 Strategy Host 进程，通过共享内存批量接收事件并返回 OrderIntent。
- Python 策略不纳入 10 μs 核心延迟保证；其崩溃、GC、异常和落后不能阻塞 TradingShard。
- Python Strategy Host 更新只重启宿主进程；原生策略代码更新重建相应 TradingShard。
- 原生分片升级时保持旧版本热备，额外启动新版本 Shadow；在序号屏障停旧、对账并切换 fencing token，随后将旧主升级为新热备。
- 参数不通过重建代码更新，参数发布规则记录在系统配置决策中。

## Comments

- 2026-07-25：初始设计访谈确认。
