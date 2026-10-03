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
原五进程 live 输出只有汇总成功行，未向机器报告提供本次订单与经济明细；现已补充
本地订单与 client ID、已应用 canonical Fill、组合费用总额及恢复摘要。报告核对身份唯一、
Fill 所属订单和成交数量；仍需当次授权的真实运行验证该新增输出，不能沿用历史成交结论。
本次离线适配器与主测试通过；真实 OKX 五进程路径在磁盘重开、RawIngress 和
CanonicalStateDigest 核对后单独输出 `windows_okx_offline=passed`，机器报告已记录
role 所有权、恢复、净量和摘要。旧 `windows-chain` 的综合历史行仍为 blocked，
不作为该离线结果的来源。独立只读链曾成功输出
`order_writes=0`；随后报告入口的只读预检收到 OKX `50102 Timestamp request expired`，
`report-readonly.json` 记录 failed，不能据此前一次独立运行填写本次 read_only=passed。
后续只读重试的执行 role 在 REST 历史补事实阶段遇 OKX transport 超时，按
`PrivateRequestUncertain` 失败关闭，controller 随后收到 `PrivateBootstrapFailed`；
未发单，不能把独立运行曾经通过的结果抄入本次报告。
源码 `b4346368` 的[离线机器报告](../report-offline.json)记录 offline、role 所有权、
恢复及两项 Windows adapter 均 passed；重试后的[只读机器报告](../report-readonly.json)
记录 REST、公共与私有 WS、五 role 及 `order_writes=0` 均 passed。两个报告绑定
相同源码树 SHA-256；先前超时失败保留在本票记录中。`demo_live=not_run`，
`windows_process_chain_verified=blocked`，`production_qualification=false`。
新增 live 成功路径的本地订单身份、已应用 canonical Fill、聚合费用和恢复摘要输出；
该路径尚未获本轮下单授权，未执行在线写入。

2026-09-30：当次 SystemOwner 授权 UID SHA-256 为
`e52bb9f5cda58fc03db5ba5b93de42450d7d69030d618c8dd8aae4adc5b70952`
的 OKX Demo BTC-USDT spot，单笔至多 25 USDT、30 分钟内同链买卖及受限清理。
当前源码五进程写验收的买单 `3966137642400235520` 已在 OKX 成交
`0.00005 BTC`，但运行器最终权威预检没有确认零敞口；
[live 报告](../report-demolive.json)记录 `failed`，其异常退出时订单写入数未知，
不能把报告未捕获的订单身份误记为零写入或完整同链买卖。
当次受限 IOC 清理遇 OKX 卖价下限高于买一；用户另行授权一次 Demo 市价清理。
该请求收到 OKX `50004` 超时，未重发；随后只读订单历史按 client ID 确认
`3966158514162909184` 全量成交 `0.00004995 BTC`。独立预检确认仅有 USDT，
无挂单、条件单、仓位、负债或 BTC。详见[失败与清理证据](../evidence-2026-09-29-06-live-failure-cleanup.json)。
直接 REST 清理不满足同链卖出条件，`windows_process_chain_verified=failed`、
`production_qualification=false`，06 继续 in-progress；再次 Demo 写验收须重新授权。
运行器原先在链异常后先抛出零敞口预检错误，遮蔽了链内原始错误；现调整为完成只读
postflight 后优先传出链异常。本次原始错误未留存，不能据卖价区间推断具体链内错误。

2026-10-03 续收口：脚本修复已提交为 `c18aad56`。2026-09-30 基于该 revision
重新生成的离线报告 passed；只读首次运行遇 `PrivateBootstrapFailed`，无写入重试后
passed。两份最终报告绑定相同源码树 SHA-256
`c6905247aee03356a182b760dd1b4ef54390de961a584c27297d2baf18e4d687`，
只读报告 `order_writes=0`。报告保留运行时 revision 和源码树身份；报告封存提交本身
不冒充新的验收运行。仍缺该源码的获授权同链真实买卖、经济明细与最终对账闭环，
本票继续 in-progress。
