# 实现 checkpoint、日志追赶与恢复屏障

Type: implementation
Status: resolved
Blocked by: 04
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

如何用 PortableStrategyState checkpoint 和分片决策日志恢复 StrategyCursor，并证明恢复期间
无交易权限、追赶到固定屏障后状态与无故障运行一致？

## Done when

- checkpoint 使用稳定显式 schema、内容校验和幂等身份，不包含 Python 对象序列化。
- 缺口或批次年龄超过 50 ms 时进入 NeedsSnapshot/Recovering 并抑制全部 intent。
- checkpoint + replay 到 CutoverBarrier 后的策略状态、游标和后续 intent 身份与无故障运行一致。

## Activity

- 2026-07-31：已认领；实现将复用现有稳定事件编码、分片决策日志、Host 生命周期和
  activation fencing，只增加恢复闭环必需的 PortableStrategyState、追赶状态与
  CutoverBarrier，不引入 Python 对象序列化或第二条交易路径。
- 2026-07-31：已完成 `CheckpointContainer v1`：192 字节稳定头、8 MiB payload
  上限、CRC32C、SHA-256 幂等身份及严格元数据匹配；当前代表性策略状态使用显式
  `{"accumulator":i64,"event_count":u64}` 规范 JSON schema，拒绝非规范表示，
  未引入 pickle、marshal 或任意 Python 对象图。
- 2026-07-31：`Recovery` 以批次覆盖而非可见事件序号验证连续性，因此订阅过滤后的
  零事件批次仍可推进 StrategyCursor；整批先验证、复制状态后提交。恢复和双 barrier
  catch-up 均推进确定性状态及 IntentSequence，但所有 intent 被抑制；只有核心核对
  StrategyStateDigest 并 activation 后，首个 intent 才能进入既有 Gateway。
- 2026-07-31：真实 Python Host 已通过控制 pipe 接收 checkpoint/BeginRecovery/
  ActivateStrategy，通过现有 SPSC 重放和返回恢复后的 intent。Gateway 在恢复期
  额外撤销交易权，合法格式的提前 intent 也以 unauthorized 在风控前拒绝。
- 2026-07-31：验收证据为 `zig test src\main.zig -O ReleaseSafe`（5/5）、
  `zig test src\strategy_host_recovery.zig -O ReleaseSafe`（2/2）、Windows
  `strategy_host_recovery_integration`（checkpoint validated、replay equivalent、
  pre-activation intents=0、identity stable）、上一票真实交易往返回归，以及
  recovery integration 的 `x86_64-linux-gnu` 交叉编译。checkpoint 损坏后的多版本
  回退和完整 Host 故障矩阵按路线留给下一张失败轨迹票。
