---
status: accepted
date: 2026-09-06
---

# 冻结首个 Linux 生产支持合同

首个生产基线由 `src/production_contract.zig` 唯一描述，并由运行输出和资格工具核对。生产平台
只有 Linux；Windows 只保留开发和快速回归。

## Decision

- ProductionSupportMatrix 只允许 OKX、Binance、Bybit 的 SPOT 与 isolated linear USDT perpetual
  目标行。每行绑定 `explicit_qualified_account` 范围；实际 ExchangeAccount 身份、节点和风险
  上限必须在后续真实资格票中冻结。
- OKX Demo、Binance Testnet、Bybit Testnet 只作为非生产参考行。生产准入必须同时匹配 production
  endpoint、production credential、明确 ExchangeAccount、无提现权限、SystemOwner 授权和独立的
  `production_qualified` 证据；任何 Demo/Testnet 结果都不能升级它。
- Gate.io 与 Bitget 为显式 disabled 行，不属于首个生产范围。
- journal/state schema 一次性从 7 切到 8，SchemaRegistryId 为 6。旧 schema 只被拒绝，不提供
  双读、双写或迁移层。
  该 schema 冻结已由 [ADR 0006](0006-authoritative-safety-state-schema-9.md) 的安全状态扩展取代。
- 首个生产默认优化模式是 ReleaseSafe。io_uring、epoll、libcurl、专用日志线程和批量同步不是
  架构前置条件，只有目标 Linux 测量证明必要时才选择实现。
- `Journal` 仍保留为稳定 record codec；`src/durable_store.zig` 已把它接入 Linux 文件
  segment、manifest、提交同步和原子快照发布。真实目标文件系统的断电、磁盘和性能资格仍属于
  后续 production-readiness 验收，不得由 WSL 或离线摘要宣称完成。

## Consequences

构建、TradingShard schema、四分片资格输出和离线测试共享同一生产合同常量。开发期格式不再具有
生产兼容承诺；DurableStore 直接实现 schema 8，并在未知或旧格式、manifest 冲突和损坏时保持
RecoveryOnly。
