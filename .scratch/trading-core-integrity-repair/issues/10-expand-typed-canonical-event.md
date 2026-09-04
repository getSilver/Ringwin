# 10: 扩展 typed CanonicalEvent 迁移入口

Type: task
Status: resolved
Assignee:
Blocked by: [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何在保持所有现有调用和 replay 绿色的前提下，为 core input 增加明确类型化的 CanonicalEvent 形态，
停止让新增路径继续依赖固定大小 opaque payload？

## What to build

执行 expand 阶段：在旧 CoreInput 适配器旁增加版本化、类型化的核心事件载荷和唯一编码规则，并让统一
Gateway 的新端到端轨迹原生使用 typed 形态。旧日志和调用者暂时通过一个边界适配进入相同 apply
语义，不复制状态机或业务分支。

## Blocked by

- [05: 收敛为唯一 Execution Gateway](05-unify-execution-gateway.md)

## Acceptance

- [ ] OrderIntent、风险/执行事实、账户/行情事实和控制事实具有有界、显式、版本化的 typed payload。
- [ ] 新 Gateway 与 Venue 合约轨迹不再先编码到 opaque CoreInput 再立即解码。
- [ ] 旧 CoreInput 只有一个兼容适配入口，并与 typed 输入产生相同状态、错误分类和 CanonicalStateDigest。
- [ ] 未知版本、非法 tag、超界 payload 和尾随数据原子拒绝，不改变 TradingShard。
- [ ] 现有调用、旧 snapshot/log replay、Debug 和 ReleaseSafe 在 expand 阶段持续绿色。

## Evidence

- Added versioned typed `CorePayload`/`CoreTransition` and public `TradingShard.applyTyped` plus `applyTypedStable` native entry points.
- The legacy `CoreInput` adapter remains isolated to compatibility decoding and old stable records; typed application does not encode then immediately decode.
- Debug and ReleaseSafe both pass 178/178 tests, including canonical codec and replay coverage.
