# 接入 OKX 公共市场事实与缺口恢复

Type: task
Status: open
Assignee: Codex
Blocked by: 01, 02, 03, 05
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何把 OKX BTC-USDT SPOT 与 BTC-USDT-SWAP 的 InstrumentDefinitionObserved、L2BookSnapshot、L2BookDelta、ReferencePrice 和 FundingRatePublished 忠实转换为既有 CanonicalEvent，并在重复、乱序、序号缺口、重订阅和规则变化时保持失败关闭及可重放证据？
