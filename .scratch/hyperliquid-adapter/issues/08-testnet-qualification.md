# 08：Hyperliquid Adapter 功能验收

Type: task
Status: resolved
Assignee: Codex
Blocked by: [07 运行与跨所接线](07-runtime-cross-venue-wiring.md)
Parent: [模块地图](../map.md)

## Question

如何确认 Hyperliquid Adapter 支持范围内的行情、订单、私有事实、签名和恢复功能正常？

## Scope correction

2026-11-04 用户明确：本次只确认 Hyperliquid Adapter 功能。原票的跨所策略真实闭环、
节点装配、批准部署配置、对手账户、交易预算和独立在线写入授权不作为 Adapter 验收前置。
按该澄清修正本票，不将离线通过描述为真实 Testnet 成交或生产资格。

## 完成条件

- [x] 记录源码 revision、相关改动、平台、fixture 身份、命令与结果，区分离线与公开只读观察。
- [x] 经公开 Adapter 接缝验证产品/资产/规则、有限深度、公共成交、参考价、费率与健康。
- [x] 验证签名身份、支持的订单编码、撤单/查询、发送分类、拒单/部分成交、Fill/费用/账户事实。
- [x] 验证重复/冲突、两种 report/Fill 顺序、背压/限流、撤权/旧 session 和 Unknown 不重发。
- [x] 验证对账覆盖不足失败关闭、RawIngress 回放及 snapshot 加尾部恢复收敛。
- [x] 既有 Venue 完整离线回归通过；真实市场身份与网络交易未测范围明确记录，不冒充资格。
- [x] 最终证据与 Standards/Spec 复审收口，提交本票范围改动。

## Answer

源码基线 `ddc4eaad2cde73fbed99467439c735a756ed374c`，开始时工作树干净。
本次仅修正文档/验收范围，未更改 Adapter、fixture、配置或持久格式；复用已有行为测试。
功能矩阵、命令、源码/fixture 哈希及证据见
[Adapter 功能验收记录](../../../docs/hyperliquid-testnet-qualification.md)。

- Adapter/行情/核心恢复定向 ReleaseSafe：35/35，退出 0。
- 原正式离线入口：`hyperliquid_runtime_offline=passed`，退出 0；只作兼容性补充，不要求真实对手。
- 完整 `zig build test -Doptimize=ReleaseSafe`：本次运行退出 0，原日志已保留。
- 公开 Testnet metadata/book 观察已保存，未读取凭证或发送交易；该观察不作为下单/成交证明。
- 签名 SDK 向量及身份绑定由主测试入口明确导入并包含在已通过的完整套件中；额外 signer-only 编译因重复验证主动停止，不当作独立通过结果。
- Standards / Spec 按用户修正的 Adapter 范围复审均无阻塞；相对链接、证据响应哈希和 `git diff --check` 通过。
- 按用户澄清的支持范围，Adapter 离线功能验收完成，本票 resolved；真实网络交易/生产资格未取得，不再要求项目部署与策略条件。
