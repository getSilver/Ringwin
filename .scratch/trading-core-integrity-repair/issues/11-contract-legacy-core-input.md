# 11: 删除 CoreInput 包装与重复影子状态

Type: task
Status: resolved
Assignee:
Blocked by: [06](06-route-binance-through-gateway.md), [07](07-route-bybit-through-gateway.md), [10](10-expand-typed-canonical-event.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何完成 expand-contract 的 contract 阶段，删除已无调用者的 CoreInput opaque 包装和 TradingShard
重复经济影子字段，同时让测试只观察稳定公共接口？

## What to build

把 native、Python、fixture、Venue、snapshot 和 recovery 调用迁移到 typed CanonicalEvent，改用公开
snapshot、查询或摘要验证权威状态，然后删除 legacy CoreInput、重复 encode/decode 往返、同步影子经济
字段和直接读取核心内部状态的兼容测试。

## Blocked by

- [06: 让 Binance 通过统一 Gateway 完成端到端路径](06-route-binance-through-gateway.md)
- [07: 让 Bybit 通过统一 Gateway 完成端到端路径](07-route-bybit-through-gateway.md)
- [10: 扩展 typed CanonicalEvent 迁移入口](10-expand-typed-canonical-event.md)

## Acceptance

- [x] 全部生产调用与测试使用 typed CoreTransition/CanonicalEvent 或稳定公共查询接口，不再构造 legacy CoreInput。
- [x] 代码库不存在固定 2048 字节 core payload、对应兼容 codec 或仅服务于该包装的转换路径。
- [x] 仓位、余额、PnL、Ledger、reservation 和投影摘要各自只有一个权威存储，不需要同步 shadow state。
- [x] 测试不直接写入或比较 TradingShard 内部兼容字段，而由 apply、snapshot、公开查询和 digest 证明行为。
- [x] 旧持久证据按明确版本处理：旧 CoreInput event type 不再存在，stable typed journal 保留 schema/version 校验并拒绝非法 tag、版本和尾随数据；CanonicalStateDigest 字节语义保持不变。
- [x] Debug、ReleaseSafe、单/四 shard、Python 及三 Venue 离线契约在 contract 后全部通过。

## Evidence

- `CoreInput` 已从 `CanonicalEvent`、canonical codec、TradingShard apply/replay、fixture、recovery 和 coordinator 调用链删除。
- stable journal 的 typed payload 改为调用方提供的有界 buffer；时间元数据随 `CoreTransition` 保存，旧 schema/flag 仍按版本严格解码。
- TradingShard 的仓位、余额、费用、PnL 和 ledger scalar shadow fields 已删除；公共 `economicSummary` 与 `economics.Projection` 是唯一查询/存储来源。
- `zig build test`：178/178 通过；四 shard evidence digest 未漂移；`git diff --check` 通过；源码不再包含 `CoreInput`、`core_input` 或 core `2048` payload。
