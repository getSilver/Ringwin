# 10: 扩展 typed CanonicalEvent 迁移入口

Type: task
Status: resolved
Assignee:
Blocked by: [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何让 core 与 Venue 输入共享一个明确、类型化的 CanonicalEvent 边界，并只通过一套 stable journal
协议进入 replay？

## What to build

完成 expand-contract：先迁移调用者，再让 `CanonicalEvent` 以 `core`/`venue` 两个有界分支承载全部
权威输入。`TradingShard.apply`、stable journal 与 replay 使用同一类型和同一编码协议，不复制状态机、
输入元数据或持久化分支。

## Blocked by

- [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)

## Acceptance

- [x] OrderIntent、风险/执行事实、账户/行情事实和控制事实具有有界、显式、版本化的 typed payload。
- [x] Gateway 与 Venue 合约轨迹不再先编码到 opaque CoreInput 再立即解码。
- [x] core 与 Venue 输入只经 `CanonicalEvent`、`TradingShard.apply` 和一套 stable journal/replay 协议演进。
- [x] 未知版本、非法 tag、超界 payload 和尾随数据原子拒绝，不改变 TradingShard。
- [x] journal/state schema 显式升级为 7；当前 snapshot/log replay、Debug 和 ReleaseSafe 持续绿色。

## Evidence

- `trading_shard_event.CanonicalEvent` 是唯一输入 union，包含 `core: CoreEvent` 与
  `venue: canonical.EventRecord`；Venue 私有 payload 类型更名为 `canonical.Payload`。
- `TradingShard.apply(CanonicalEvent)`、`applyStable` 与 `decodeStableInput` 共用一套类型；journal 只保留
  `input_flag`，payload 首字节区分 core/venue，不再存在双协议。
- 新增 malformed stable envelope 回归，覆盖旧 schema、空载荷、非法 tag、尾随数据和超界编码；
  Debug/ReleaseSafe 均通过 185/185。
