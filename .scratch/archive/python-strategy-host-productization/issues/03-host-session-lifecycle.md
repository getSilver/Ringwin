# 实现 Host 握手、会话与进程生命周期

Type: implementation
Status: resolved
Blocked by: 02
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

如何启动四个 Host，完成兼容握手、分配 HostSessionIdentity、监督退出/卡死并拒绝旧进程迟到输出，
而不让 supervisor 或 Python 进入 TradingShard 权威状态？

## Done when

- Host 启动、握手、Ready、停止、崩溃和重建具有确定状态机与有界超时。
- 协议/schema/策略构建/checkpoint 不兼容时 Host 不获得交易权限。
- 旧 session 的 intent、确认和 checkpoint 发布全部被核心拒绝。

## Activity

- 2026-07-31：已认领；实现严格复用已冻结 Compatibility → Recovery → Activation
  契约和 `src/strategy_host_ipc.zig` 的匿名映射所有权，不提前接入 TradingShard
  业务状态或 checkpoint 内容。
- 2026-07-31：新增 `src/strategy_host_lifecycle.zig`，形成小型 `HostSupervisor`
  interface；状态固定为 Starting、ReadyForRecovery、Stopping、Stopped、Failed。
  `HostHello` 精确通过后只进入 ReadyForRecovery，未增加“进程已启动即有交易权”的旁路。
- 2026-07-31：实现 64 字节 `ControlFrameV1`、双向连续 ControlSequence、CRC32C、
  长度前缀匿名 pipe 和 SessionPlan/HostHello/Heartbeat/Shutdown/ShutdownAck 最小
  白名单；未知类型、版本、flags、CRC 或当前会话序号异常均使会话失败关闭。
- 2026-07-31：Compatibility 精确比较协议、SchemaRegistry、Host build、Python
  major/minor ABI、策略清单、checkpoint 清单和完整 SessionPlan SHA-256；任一不符
  均停在 Failed，不能进入恢复或交易授权。
- 2026-07-31：启动超时、主循环 heartbeat timeout 和 shutdown grace 均来自
  SessionPlan fixture 参数；crash、hang 和超时先使 session Failed，随后终止并
  回收旧 pipe/共享内存，再以严格递增 HostGeneration 创建全新进程和资源。
- 2026-07-31：新增 `python/strategy_host.py` 作为无第三方依赖的最小 Host 进程；
  它只执行冻结控制握手和主循环 heartbeat，不接触 TradingShard 权威状态，也不在
  本票提前实现策略回调、checkpoint 内容或 OrderIntent。
- 2026-07-31：`zig test src\strategy_host_lifecycle.zig -O ReleaseSafe` 覆盖六类
  不兼容、启动/heartbeat 超时、重启 generation 和旧 session fencing；同时回归
  已完成的共享内存 IPC 检查。
- 2026-07-31：`zig run src\strategy_host_lifecycle.zig -O ReleaseSafe` 同时启动
  四个真实 Python 子进程，并通过正常握手/停止、crash 重建、hang 强制终止重建及
  旧 session intent/confirmation/checkpoint 包络拒绝，输出全部 `ok/blocked`。
- 2026-07-31：Python 语法检查、Linux `x86_64-linux-gnu` 交叉编译和原交易引擎
  三项 ReleaseSafe 回归全部通过；父进程异常退出的 OS 级 Job Object/PDEATHSIG
  资格轨迹留在后续“实现异常、卡死、崩溃与过载失败轨迹”，本票 resolved。
