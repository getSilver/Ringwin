# 实现异常、卡死、崩溃与过载失败轨迹

Type: implementation
Status: resolved
Blocked by: 05
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

单策略异常、不可抢占卡死、Host 崩溃、输入落后、输出通道填满、checkpoint 损坏和旧会话迟到时，
系统如何失败关闭且不阻塞其他 Host 或 TradingShard？

## Done when

- 普通异常只停用对应 StrategyInstance；卡死/崩溃只重建对应 Host。
- 输出通道满不静默丢 intent；受影响 Host 失去交易权限并进入明确恢复。
- 四 Host 故障矩阵自动验证无重复 intent、无旁路订单、无核心阻塞及健康 Host 游标连续。

## Activity

- 2026-07-31：已认领；实现将复用现有四 Host 生命周期、SPSC 失败关闭、session/
  activation fencing 和 checkpoint 恢复路径，补齐故障矩阵与可运行证据；不引入
  自动重试队列、通用任务框架或会阻塞 TradingShard 的同步恢复。
- 2026-07-31：已增加稳定 `StrategyFaulted` 与 `RecoveryRequired` 控制事实。
  Python 回调先在临时状态/输出中执行；单策略异常丢弃临时 intent、保持原 cursor
  并只禁用该策略，Host session 与健康策略保持 active。输入完整性失败或输出 FULL
  则由 Supervisor 立即失败关闭整个 session。
- 2026-07-31：Gateway 的 session 切换现在只清除传输批次并默认撤权，保留跨 session
  的业务 intent 身份历史。AcceptedBeforeFence 的重放命中 duplicate；
  PublishedButNotAccepted 在旧 session 被拒绝后可由新 session 接受恰好一次，
  均不产生重复风险占用或旁路订单。
- 2026-07-31：四个真实 Python Host 的同轮矩阵已覆盖单策略异常、输出 ring 满、
  进程 crash 与健康 Host；随后以新 generation/新 pipe/新共享内存重建 crash Host，
  注入不可抢占 hang 并 kill，另以新 Host 注入未知 event schema。健康 Host 在这些
  故障之间继续从 cursor 1 推进至 2。
- 2026-07-31：IPC 批次验证已用内部时钟 seam 锁定 `50,000,000 ns` 接受、
  `50,000,001 ns` stale，以及 batch sequence/ShardSequence coverage gap 与 CRC
  损坏失败关闭；输出 `tryPublishMany` 在空间不足时保持 producer 和可见集合不变。
  checkpoint 选择器按新到旧验证 header、payload、截断、schema 和 next-sequence，
  回退旧有效版本；无有效版本时只允许显式 Rebuild，否则 Disabled。
- 2026-07-31：验收证据为 `zig test src\main.zig -O ReleaseSafe`（5/5）、
  `zig test src\strategy_host_failures.zig -O ReleaseSafe`（3/3）、
  `zig test src\strategy_host_lifecycle.zig -O ReleaseSafe`（2/2），正常交易、恢复及
  四 Host 故障三个真实 Python 往返程序全部通过；故障矩阵完成
  `x86_64-linux-gnu` 交叉编译。README 已记录可复现命令。
