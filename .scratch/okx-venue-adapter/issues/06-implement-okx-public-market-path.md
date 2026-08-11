# 接入 OKX 公共市场事实与缺口恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: 01, 02, 03, 05
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何把 OKX BTC-USDT SPOT 与 BTC-USDT-SWAP 的 InstrumentDefinitionObserved、L2BookSnapshot、L2BookDelta、ReferencePrice 和 FundingRatePublished 忠实转换为既有 CanonicalEvent，并在重复、乱序、序号缺口、重订阅和规则变化时保持失败关闭及可重放证据？

## Answer

新增 `src/okx_public_market.zig` 作为固定首波公共事实标准化边界。libcurl transport owner 只需把完整 REST/WS JSON 消息、来源 session 与既定时间传入；模块不暴露 OKX 字段给 TradingShard，也不预建多 Venue 插件框架。

- `RawSink` 在 JSON 解析或状态变更前提交带 SHA-256、来源 session、receive/monotonic/wall 时间的 RawIngressRecord；持久化背压直接返回且不产生 CanonicalEvent。每条规范事实引用稳定 raw stream sequence 与 digest。
- 只接受 BTC-USDT SPOT、BTC-USDT-SWAP 以及 `instruments/books/mark-price/index-tickers/funding-rate` 固定 schema；公共 REST bootstrap 与 WS push 共用同一 decoder。source time 缺失保持 absent，不用 receive/wall 时间伪造。
- 所有价格、数量和费率使用规范化 `i128 coefficient + scale`，不经过浮点；Instrument 候选保存既定限制、合约/结算单位、trade quote 与 `upcChg(param/newValue/effTime)`，规则变化形成新的 InstrumentDefinitionObserved，不直接替换已激活 InstrumentRules。
- `books` 只以 `seqId/prevSeqId` 判连续性，不使用已废弃 checksum，也不错误要求序号逐一递增。相同序号空更新是 heartbeat；完全重复不重发事实；冲突重复、倒序、缺口、未知 action 或损坏 book frame 立即输出带序号证据的 MarketDataHealthChanged(gap)，后续 delta 全部丢弃，只有新 snapshot 恢复 healthy。
- 重订阅显式返回不带伪造 RawIngress 的 awaiting_snapshot/resubscribed 本机健康事实，并清除旧序号；PublicMarketReady 按 Instrument 同时要求有效规则候选与连续 L2 snapshot。
- SourceFactIdentity 与内容哈希按字段确定性编码，不依赖结构体 padding、地址、JSON 空白或 `f64`；重复原始帧仍各自保留 RawIngress 证据。

2026-08-11 使用 OKX 无凭证公共 REST 只读响应核对 SPOT/SWAP instruments、funding、mark 与 index 字段形状，确认 `upcChg` 为对象数组、REST instrument 无 source timestamp。该核对不连接账户、不构成在线 WSS 或生产资格；固定 libcurl 在线 transport、订阅握手与最终公共无凭证运行仍由后续 Adapter/资格票闭合。

验证：公共模块 9 项协议测试通过；`src/main.zig` 导入后的 15 项测试在 Debug、ReleaseSafe、ReleaseFast 全部通过，既有五条权威 digest 不变；ReleaseSafe 可执行自检通过。Python StrategyHost 验收第 1–13 步通过，第 14 步首次受调度抖动在 gc_exception 超时，随后独占复跑五个百万样本场景全部通过。
