# 冻结首个 Linux 生产合同与 schema

Type: task
Status: resolved
Assignee:
Blocked by:
Parent: [Linux 生产资格收口](../map.md)

## Question

如何消除当前规范、文档和源码中的生产范围矛盾，并在不保留开发期向后兼容的前提下形成唯一、
失败关闭的首个 Linux 生产基线？

## What to build

形成一份可由构建、运行和资格工具共同读取或核对的生产支持合同：Linux 唯一生产平台，支持
OKX、Binance、Bybit 的明确 SPOT/USDT 线性永续能力，其他环境、Venue、产品与订单能力默认拒绝。
一次性提升当前未投产 journal/state schema，删除兼容影子路径，并使文档只描述已经实现或明确
未资格的事实。

同时解决两项已知规范冲突：旧研究中的 Gate.io/Bitget 候选不覆盖当前 OKX/Binance/Bybit 实现；
性能门槛是生产合同，而 io_uring 只能是目标机测量后选择的 implementation，不能成为无证据的
架构前置条件。

## Acceptance criteria

- [x] 唯一支持矩阵列出 Venue、Environment、ExchangeAccount、产品、Instrument、订单能力与明确禁用项。
- [x] 生产环境不会从 demo/testnet 配置、endpoint、header、凭证或资格状态隐式升级。
- [x] journal/state schema 一次性提升；旧开发格式被明确拒绝，不存在双读、双写或迁移层。
- [x] README、领域规范、ADR、构建说明和资格输出不再把内存 journal 表述为已完成真实持久化。
- [x] Gate.io/Bitget 与 OKX/Binance/Bybit 的冲突，以及强制 io_uring 与按测量选型的冲突均有唯一结论。
- [x] ReleaseSafe 被记录为首个生产默认构建，Windows 被明确限定为开发回归。
- [x] 离线核心测试和固定摘要按新 schema 更新后全部通过；旧 schema 拒绝路径有自动测试。
- [x] map 的 Not yet specified 只保留必须依赖真实节点或账户才能决定的值。

## Out of scope

- 实现 Linux 进程、磁盘持久化、真实凭证或在线下单。

## Answer

已冻结首个 Linux ProductionSupportContract，代码唯一入口为
`src/production_contract.zig`。ProductionSupportMatrix 固定 OKX、Binance、Bybit 的 SPOT 与
isolated linear USDT perpetual 目标行；OKX Demo、Binance Testnet、Bybit Testnet 仅保留非生产
参考行，Gate.io 与 Bitget 显式禁用。生产准入要求同一 production endpoint、credential、明确
ExchangeAccount、无提现权限、SystemOwner 授权和独立 `production_qualified` 证据。

journal/state schema 已从 7 一次性提升到 8，旧 schema 测试通过拒绝路径验证；没有双读、双写或迁移。
`ReleaseSafe` 是首个生产默认构建，io_uring/epoll 只保留为目标 Linux 测量后的实现选择。当前
Journal 仍是离线有界内存 codec，真实磁盘持久化留给票 03。

## Evidence

- WSL Linux target compile：通过 WSL 调用 pinned compiler `'/mnt/d/Program Files/zig/zig.exe' test src/main.zig -target x86_64-linux-gnu -OReleaseSafe --test-no-exec`。
- WSL 生成并运行 Linux ELF 核心入口：schema `2`、journal/state `8`、四分片 barrier `17`、
  shard barriers `23/26/21/21`，共享摘要
  `841e5425827f7d12ba771fd2de14303bfb4923b22a4cc6615cd7d348b8332dfe`。
- Windows 开发回归：Debug/ReleaseSafe 各 `188/188` 通过；Linux WSL1 的 StrategyHost IPC
  运行测试因内核不支持 `memfd_create`（errno 38）未作为 Linux 生产资格证据，Linux 目标编译仍通过。
