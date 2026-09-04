# 11: 删除 CoreInput 包装与重复影子状态

Type: task
Status: active
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

- [ ] 全部生产调用与测试使用 typed CanonicalEvent 或唯一的稳定公共查询接口，不再构造 legacy CoreInput。
- [ ] 代码库不存在固定 2048 字节 core payload、对应兼容 codec 或仅服务于该包装的转换路径。
- [ ] 仓位、余额、PnL、Ledger、reservation 和投影摘要各自只有一个权威存储，不需要同步 shadow state。
- [ ] 测试不直接写入或比较 TradingShard 内部兼容字段，而由 apply、snapshot、公开查询和 digest 证明行为。
- [ ] 旧持久证据按明确版本迁移或明确拒绝；不得猜测解析，也不得静默改变 CanonicalStateDigest 语义。
- [ ] Debug、ReleaseSafe、单/四 shard、Python 及三 Venue 离线契约在 contract 后全部通过。

## Evidence

- Expand stage is implemented and verified through `applyTyped`/`applyTypedStable`.
- Contract stage is intentionally not closed yet: `CoreInput`/2048-byte compatibility storage and scalar economic compatibility fields still exist for old journals/tests and require a separate migration before deletion.
