# 封存 Windows OKX 业务证据与文档

Type: task
Status: in-progress
Assignee:
Blocked by:
Parent: [Windows OKX 业务进程链验证](../map.md)

## Question

如何从实际运行结果封存可核对的 Windows OKX 端到端业务证据，并避免把离线、
只读、Demo 写入或 Windows 结果错误升级为生产资格？

## What to build

统一 `zig build` 入口与机器可读报告。报告记录源码 revision、当前 acceptance/journal/state
schema、环境、Venue、账户/产品/策略/配置身份、模式、role 与 IPC 证据、持久化与恢复摘要、
真实 OKX 订单/成交/费用/终态及清理结论；身份和经济字段按需脱敏，不含凭证。
README 中英文、ADR、CONTEXT 和本地图与实际源码及验收一致。独立记录
Windows DurableStore/CredentialStore 适配器结果、离线 OKX 业务结果、在线只读结果及
获授权的 Demo 写入结果；所有失败与未运行项保持显式状态。

## Acceptance criteria

- [ ] `zig build` 有可重复且失败即停的 Windows OKX 离线业务入口；真实 Demo 写入口
      与只读入口明确分离，默认不执行在线写入。
- [ ] 只有 05 全部验收及真实 Demo 终态闭合后，才输出
      `windows_process_chain_verified=passed`、`venue=okx`、`environment=demo`
      与 `production_qualification=false`；否则为 failed、blocked 或 not_run。
- [ ] 报告包含实际源码/schema、账户/产品/策略/配置范围、身份与恢复/账本证据；
      不使用硬编码的历史测试数、模拟数据或手写布尔值自授资格。
- [ ] README.md、README.zh.md、ADR 0008、CONTEXT、生产地图引用与当前结论一致；
      不把 Windows Demo 结果写成 Linux 02–11、Binance/Bybit Testnet 或生产合格。
- [ ] 全部条件实证完成后才将本图和本票标为 resolved/closed；未获在线写授权时保持开放。

## Historical evidence

旧票曾按 SimulatedVenue 范围封存 `247/247` 和 schema 7/14/15；
这些数字已与当前源码不符，不能用于新 OKX 业务结论。

## Progress

2026-09-30：新增 `zig build windows-okx-offline`、`windows-okx-readonly` 与显式授权的
`windows-okx-live` 分离入口；PowerShell 报告从运行结果和当前源码生成 revision、源码树
SHA-256、schema、模式及脱敏账户范围，并在跨模式合并时核对源码和账户。历史 2026-09-29
成交证据保留为历史来源，不能自动升级当前源码。当前没有新的有界 Demo 写入授权；最终源码
尚无匹配的在线真实成交报告，本票继续 in-progress，资格保持 blocked。
当前五进程 live 输出只有汇总成功行，尚未向机器报告提供本次订单 ID、经济 Fill 和费用；
报告因此即使读到汇总成功也不授予 `windows_process_chain_verified=passed`。
本次离线适配器与主测试通过，但历史 `windows-chain` 自报 `offline=blocked`，机器报告
因此将完整 OKX offline、role 所有权和恢复继续标为 blocked。独立只读链曾成功输出
`order_writes=0`；随后报告入口的只读预检收到 OKX `50102 Timestamp request expired`，
`report-readonly.json` 记录 failed，不能据此前一次独立运行填写本次 read_only=passed。
