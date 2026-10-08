---
status: accepted
date: 2026-10-08
---

# Windows 与 Linux 独立取得生产资格

根据 SystemOwner 的明确要求，Windows 与 Linux 均可作为 ProductionPlatform 候选。
本决策取代 ADR 0002 的 Linux-only 限制及 ADR 0008 对 Windows 平台永久排除生产资格的表述；
ADR 0003 的 Linux 实现要求继续适用于 Linux。平台可获资格不等于当前版本已通过资格。

## Decision

- 两个平台使用同一交易核心、容量、经济正确性和失败关闭合同，各自绑定操作系统版本、节点、
  文件系统、ReleaseArtifact、Venue、账户、配置及能力范围取得 ProductionQualified。
- Windows 不以 Linux 通过为前提；Linux 证据也不由 Windows 结果替代。Demo/Testnet 和
  WindowsProcessChainVerified 仍不能自动升级为生产资格，既有验证报告及失败结果保持原范围。
- Windows 生产收口须独立证明常驻进程管理、最小权限与 IPC 身份、持久 generation、业务排空、
  磁盘同步/原子发布/断电恢复、凭证内存与转储保护、Web 控制与签名发布、遥测、外部 NodeFence
  和主备恢复。可复用现有 Windows 业务实现，但不能仅重命名 VerificationRole 或修改布尔值。
- 两个平台都须完成约定容量与性能、故障矩阵、72 小时 soak、生产只读影子和另行授权的 Canary；
  API 名称相似或功能测试通过不能证明 OS 安全及耐久性等价。

## Consequences

当前仅修订文档与计划，不修改实现代码。src/production_contract.zig 仍为 Linux-only，
Windows 生产 dispatcher、准入与报告尚待实现和独立验收；当前无新增生产资格。
后续实施须让平台身份进入支持矩阵、准入、ReleaseArtifact 和报告校验，保持缺证据时失败关闭。
现有 production-readiness 地图保留为 Linux 专项；核心容量波次同时服务两个平台，Windows
平台专项合同和目标机证据须单独拆分，不把已关闭的 Windows Demo 波次改写为生产验收。
