# 03: 将单一 Instrument 配置扩展为有界注册表

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何把 TradingShard 的单一 InstrumentIdentity 和规则版本扩展成有界、多 Instrument 权威配置，同时
保持既有单 Instrument 行为并停止用特殊整数猜测产品类型？

## What to build

为每个规范 InstrumentIdentity 注册明确的 Venue、产品类型、InstrumentRules、MarginModel 和规则版本。
风险、OMS、执行回报和经济投影都从注册项取得语义；既有单 Instrument Genesis 继续作为受支持输入，
但立即归一化到相同注册表，不形成第二份权威状态。

## Blocked by

None (can start immediately).

## Acceptance

- [ ] 同一 TradingShard 可以注册至少一个 SPOT 和一个 isolated linear USDT 永续 Instrument，身份互不覆盖。
- [ ] 产品和保证金语义来自注册项，不再根据 InstrumentIdentity 等于某个特殊数值进行分支。
- [ ] 重复注册完全相同的配置为幂等；身份冲突、规则版本倒退或超过容量均原子拒绝。
- [ ] 单 Instrument Genesis 的现有成功与失败轨迹保持兼容，并归一化为一个注册项。
- [ ] registry、活动规则版本和产品语义进入稳定 snapshot、restore 和 CanonicalStateDigest。

## Evidence

- Added bounded `src/instrument_registry.zig` with explicit venue/product/rules/margin entries, idempotent registration and atomic conflict/capacity rejection.
- `TradingShard` resolves risk, OMS, execution reports and fills from registry entries; legacy Genesis is normalized into the same one-entry registry shape.
- Registry state is validated in snapshot restore and included in the canonical digest.
- `zig test src/main.zig`: 178/178 passed; four-shard digest baseline refreshed to `e124735e7c33b86358e0a9fe23d9d1a51a86436627821b7cfc48ffbfc7f23476`.
