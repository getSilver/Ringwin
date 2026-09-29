# 修订 Windows OKX 业务验证合同

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [Windows OKX 业务进程链验证](../map.md)

## Question

如何把原 SimulatedVenue 进程验证合同修订为单一 OKX Demo 业务链，同时保证
Windows、Demo、Linux 生产三种证据不能互相升级？

## What to build

核对当前源码与文档，修订 ADR 0008、CONTEXT、`WindowsChainEvidence` 和资格输出的范围。
明确 OKX Demo 的离线、只读、授权写入三种独立结果；`WindowsProcessChainVerified`
只有在真实 role 所有权及本图业务链验收都通过时才可为 true。冻结账户、产品、策略、
配置和证据字段；取消“SimulatedVenue 是本波唯一执行角色、OKX Demo 独立运行”的旧决定。
不更改 ADR 0002/0003 和 Linux `permitsProduction()`。

## Acceptance criteria

- [x] ADR 0008、CONTEXT、README 与源码合同不再把 SimulatedVenue 链误写为本波 OKX
      业务证据；旧模拟结果保留为历史回归。
- [x] 证据按 `offline`、`read_only`、`demo_live` 区分；只读或离线不能冒充真实成交，
      失败/未运行不得输出 passed。
- [x] 证据范围含源码 revision、环境、Venue、账户、产品、策略及配置；谓词仍不能使
      `permitsProduction()` 为 true，也不能提升 Binance/Bybit Testnet 状态。
- [x] `.env.local` 仅定义为 Demo 凭证输入；任何真实写入仍要求当次有界 SystemOwner 授权。
- [x] Linux `--production-role` 与 ADR 0002/0003 不被 Windows 验证入口替换。

## Answer

2026-09-27：`WindowsChainEvidence` 现在要求 OKX Demo 的源码、账户、产品、策略与配置范围，
以及离线、只读、真实成交、role 所有权、磁盘恢复和最终对账各自通过。
历史 SimulatedVenue 链不再构造通过证据；ADR 0008、CONTEXT 与双语 README 已更新。
`zig test src/production_contract.zig` 7/7、`zig test src/windows_verification_runtime.zig` 9/9。
`zig build windows-chain` 仍在 `HostIntentBeforeActivation` 失败，归票 05 修复；
`zig test src/main.zig` 在第 82/297 项栈溢出中止，不作为本票通过证据。

## Historical evidence

2026-09-17 的旧合同曾冻结 Windows 验证 role、Named Pipe 与非生产边界；
其“只接 SimulatedVenue”范围因 2026-09-27 用户修订而需要重新决策。
