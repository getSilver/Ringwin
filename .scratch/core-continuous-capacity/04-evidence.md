# 04 多交易对观察与选择性交易证据

Status: resolved

实施工作树为 `D:\github\Ringwin-core-continuous-capacity`，分支
`codex/core-continuous-capacity`。双轴审查基线为 `7cac2d42`；最终业务源码为
`9bf7650892c25255ffe20b6d5af7f4e005738897`，Git tree 为
`08588b5ac066cf6cc68c20e8698aedcb275b2fec`。本票不授予千单、平台或 Venue 资格。

## 业务结果与恢复

新增公共验收通过固定的 MarketFeedAdapter/VenueAdapter 接口持续驱动四个
Owner；每 Owner 登记 125 个不同 Instrument（75 spot、50 linear），共 500 个
组合。四条离线路由容量包括明确的模拟第四 Venue，未增加第四家线上协议。
每条路由保持一条公共和一条私有输入流；不是给每个品种复制连接或 Owner。

选择前经过八轮全部品种观察，OMS 订单为零。每 Owner 实际保留 76 个资产余额、
125 个仓位和 50 个独立保证金投影；每条 account 消息容量仍为 8，驻留容量独立。
每 Owner 最终有 32 个选中存活订单、一个撤销终态，共 128 live；每条路由实际
发送 32 个初始 place、一次 cancel 和一次重新授权 place。不同 Venue、产品、
Instrument、资产单位和账户使用独立规范身份。

选择授权绑定账户、策略激活、配置版本、Instrument 与独立选择版本；真实
CapabilityProfile.version 保持 1，不伪造 SDK 能力变化。授权重复不新增事实；
停用拒绝新单、允许已存在单撤销，重新启用产生新证明。市场缺口按 Instrument
隔离；已经获准但尚未发送的增加风险命令也由 Gateway 复核当前品种健康。

每 Owner 应用四个实际部分成交，覆盖不同 spot/perp 数量单位。第二 spot 的
手续费使用第一 spot 的 base asset；重复 Fill 无副作用，两个经济层的原生资产、
数量与成本守恒，并在快照恢复后保持一致。不是用 OMS reported cumulative
替代唯一已应用 Fill，也不跨品种相加数量。

每条路由检查点恢复后比较完整 CanonicalStateDigest、125 个规则、32 live、
33 个 resident 订单、账户投影与选择状态；恢复准入仍有 fence。第 126 个配置
组合明确拒绝且摘要不变；错误账户、Venue、scope 与 metadata 同样拒绝。
合法 SDK 的 asset scope 余额、instrument scope 仓位和 account scope 保证金
均有正向回归，避免只接受不符合实际适配器的 account-only fixture。

## 格式、容量与已有调用者

[ADR 0012](../../docs/adr/0012-bind-observation-and-trading-state-to-instruments.md)
说明品种选择、行情、保证金、仓位与货币汇总边界。StateDigestV8 绑定全部
品种保证金阈值和选择权限及完整经济投影；journal/state/registry 升至 33/37/31，
私有恢复 DTO schema 为 2，旧格式失败关闭。codec 递归解码写入目标对象，保留
CRC、摘要、tag 与计数检查，避免返回大型数组的额外临时复制。

500 组合公共验收最终 Debug/ReleaseSafe 最大编码快照 **432,940 字节**，TradingShard
布局 **863,568 字节**；Store 快照上限为 1 MiB。OMS 当前 33 个 resident 槽是
32 selected live 加一个尚未迁出的终态，已有 shortcut 注释；这不是 09 的
1,024 live 与独立 4,096 terminal 合同。production 的 2 MiB 栈、复制、RSS、
保留索引和吞吐资格尚未取得。

既有 OMS、原生资产、多 Venue、四分片、私有 Fill 与恢复调用者补齐新选择授权、
正确 Instrument 标记价格和公共市场事实。五条既有轨迹先运行独立业务状态、
账本和 replay 断言，再迁移 V8 固定摘要，见 [日志](04-golden-business-replay.log)。
四分片共享风险断言保留，Debug/ReleaseSafe 得到相同新摘要后再更新期望。

## 审查与验证

GPT 6.1 Sol、中等强度双轴审查及修订复核。Standards 最终无硬性违规或
actionable smell；重复 125 上限已统一到 canonical 常量。Spec 原两项 P1 均有
实际 RED 与修复：Gateway 对 pending place 的市场缺口复核，以及 account 输入
在 semantic duplicate 之前验证 Venue/scope。修订源码无剩余 actionable 发现。
见 [Gateway RED](04-gateway-market-red.log)、[Debug](04-gateway-market-debug.log)、
[ReleaseSafe](04-gateway-market-releasesafe.log) 与
[account RED](04-account-scope-red.log)、[Debug](04-account-scope-debug.log)。

最终 ReleaseSafe 全套 **461/461**，见 [日志](04-full-releasesafe-final.log)；
最终 Debug **461/461**，见 [日志](04-full-debug-final.log)。测试显式使用 256 MiB 栈，
不能宣称满足生产栈限制。ReleaseSafe 构建退出码 0，stdout/stderr 为空，见
[构建日志](04-build-releasesafe.log)。`zig fmt --check` 与 `git diff --check` 均通过。
源码与 artifact SHA256 见 [构建身份](04-build-metadata.json)，全部原始日志长度及
SHA256 见 [清单](04-log-hashes.json)。

## 失败与剩余范围

保留所有局部 RED、整套中间失败及中断日志。中间 Debug 450/461 的原生单品种
fixture 未重映射新增授权；中间 ReleaseSafe 460/461 的 pending IntentGroup
fixture 只赋 operation，留下未初始化 client_order_id.len，编码时错误拒绝。
两者均修正调用者，保留原业务断言。此前 account-only scope 修订也保留了被
真实 SDK 正向回归揭示的失败，再按 payload scope 修正共享入口。

05–12、订单/经济/控制历史归档与保留删除、千单、长期混合负载、实际资源预算
和 Windows/Linux 文件容量尚未完成。未部署、未访问真实交易账户或同步 GitHub。
