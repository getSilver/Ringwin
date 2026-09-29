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
