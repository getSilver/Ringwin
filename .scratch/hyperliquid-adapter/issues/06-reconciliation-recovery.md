# 06：对账、Unknown 与持久恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 订单与私有事实](05-orders-private-facts.md)
Parent: [模块地图](../map.md)

## Question

如何在启动、断线和重启后证明订单及经济事实完整，无法证明时保持未解决状态？

## What to build

复用既有对账、Owner、DurableStore 与恢复屏障；Adapter 查询与输出证据，不直写 OMS/账本或解除锁存。遵循 ADR 0014 的成交归档与 ADR 0021 的安全恢复边界。

## 完成条件

- [x] 订单、成交、余额、仓位、保证金、费用、资金费及强制执行的完整范围和分页终止明确；REST 与实时 WS 交错有确定缓冲/去重规则。
- [x] 覆盖部分/取消/Reduce-only 订单、终态后迟到 Fill、重启重载及历史延迟/截断；不得只复用参考项目有限的普通全成交单补回逻辑。
- [x] Unknown 保留原命令身份、可能成交范围及风险占用；一次未找到、空页、超时或最近记录窗口不足都不能伪造未发生证明。
- [x] 相同事实幂等、矛盾内容失败；真实费用不能由推算替代，余额差不补造 Fill，历史不可查证保持 pending/安全限制。
- [x] 通过公开原始输入→Adapter→applyAdapterBatch→TradingShard→DurableStore 验证故障位置，RawIngress 回放与 snapshot 加尾部重放的 CanonicalStateDigest 收敛。
- [x] 覆盖归档后重复成交、旧 session、恢复中再次断线与缓冲耗尽；重放零发送，恢复不重发、不延长期限、不重新授权。
- [x] 原因解除、锁存解除与交易恢复按现有核心合同分别处理；记录实际命令和结果，不用 helper 测试代替公开链路证据。

## Answer

实现基线：`00089dcecc6f373346e22712807978b7a8560b67`；分支 `feat/hyperliquid-adapter`。本票为离线实现，不授予 Testnet 写入或生产资格。

### 恢复范围和安全边界

- `HyperliquidVenueAdapter` 使用既有 `AccountReconciliationRequest` 的固定经济起止边界，绑定 Venue、环境、资金账户、session、Instrument/Asset 与规则版本。依次读取 `userAbstraction`、`clearinghouseState`、`spotClearinghouseState`、`frontendOpenOrders`、`historicalOrders`、`userFillsByTime`、`userFunding`、`userNonFundingLedgerUpdates`。不使用 agent 地址，不从余额差或报告累计量制造成交、费用或资金费。
- `tryDrain` 每轮至多一次只读查询或 16 行转换；一页最多使用现有 RawIngress 的 `max_frame_bytes`（16 KiB 减两层记录头），JSON 工作区 512 KiB，总共至多 16 页，查询期限定为开始时固定的 30 秒，不在恢复中续期。时间边界精确到毫秒，不默默截断纳秒；成交查询固定 `aggregateByTime=false`。满 500 行时从最大时间 inclusive 重叠；同毫秒无法前进即 stalled，不使用 `timestamp+1`。大帧、驻留事实或页预算耗尽明确保持容量不足，不丢弃后续行来声称完成。
- 页覆盖记录包含原请求、固定边界、来源原文引用、行数、最小/最大时间与终止原因。请求原文、页响应和恢复终止标记均先提交 RawIngress。短页/空页仅标记可访问集合耗尽；`historicalOrders` 最近 2,000 单、Fill 最近 10,000 条保留上限不证明窗口完整。官方依据延续 [Info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint) 及已批准 01 合同。
- 账户模式、持仓/spot 余额增量沿用 05 的批准资产与已有 bootstrap 绑定。逐仓摘要不猜测完整可用金额、负债或共同快照屏障；费用来自独立真实 Fill，资金费修订键、强平/ADL 完整来源尚不可证明时保留原文并安全失败。因此本实现的整体账户 `complete` 始终为 false；即使八项查询均为空，也不建立完整账户/经济窗口或 ConfirmedAbsent。
- 同时只保留一页和一批输出。待处理页阻止接收新 WS 帧；调用方必须保留未受理帧并对上游施加背压，不允许丢弃。页 drain 之后，WS 与 REST 的同事实经同一身份/内容检查去重；矛盾、旧 session、未知资产、错误订单归属及未知强制执行均失败关闭。真实 transport 的有界接收 pump 与出口聚合预算仍由 07 接线。

### Unknown、重载和原始回放

- transport 前持久捕获完整原命令上下文，捕获后再次检查当前时钟、期限、权限和 fencing。发送响应与发送 outcome 分别记录，回放按原命令关联响应；缺上下文/缺 outcome 的尾部不能通过 `finishReplay`，不能重新签名发送。只有确定 transport 未提交时返回 not_sent；Unknown 保留原 CLOID、命令、可能 oid、数量和原期限，后续拒绝重试不清除其原状态。
- 查询结果自身也有原始记录，包含未找到、查询失败和无经济边界的 account fallback。没有正面终态证据的订单保持 unresolved；已见真实终态报告的订单保留该报告及其原始证据，后来的 `unknownOid` 不能把它回退为 Unknown。`found_terminal` 只确认已有正面订单状态，不提供 terminal archive 或经济完整性资格。
- `exportResumeCheckpoint` / `restoreResumeCheckpoint` 复用现有裸 snapshot codec；检查点包含绑定摘要、原命令与 oid/Unknown、正面终态证据、128 项去重事实、canonical/raw 高水位及故障状态，不包含 transport、指针、凭证或授权。绑定摘要包含固定产品、批准 token/Asset、激活资产/品种及版本；旧绑定、混合资金地址、错误 session 和不一致的终态证据拒绝。
- Owner 以既有 `checkpointPrivate` 的 seed digest、原文 archive root、canonical barrier 和 core digest 绑定这些字节。回放实例拒绝 `trySend` 和 live ingest，`replay` 仅消费已提交原文。公共消费方重建全部 decoder 状态，按已提交核心来源游标只应用未提交的 canonical 尾部；不能把旧安全事件再次应用为新事实。`finishReplay` 还要求上下文与恢复工作全部闭合，未闭合保持恢复限制。
- `resumeReadOnly` 仅允许后续查询/撤单；保留 recovery_required 与原故障，不赋予新增风险。原因、锁存和 TradingAuthorization 仍由既有核心分别管理。主动断线标记和恢复终止标记可回放；任何恢复、重连、重启均不延长原订单期限或恢复人工授权。
- 驻留上限仍为 64 个订单关联、128 项事实；不增加未被要求的冷历史缓存或自动淘汰。超过这些上限需要已有核心业务历史的经资格验证的连续承接，本票不把定向小规模验收冒充容量资格。

### 公开验收与审查

- 扩展已有 `hyperliquid_execution_acceptance.zig`，沿真实 Gateway 的持久 CLOID、DurableSink、Owner.applyAdapterBatch、TradingShard 与 Store 路径验证：发送完成但尚未 canonical 应用时的重启；原文成交/报告已提交但尚未核心应用时的重启；report→Fill 与 Fill→report；规范 snapshot 加尾部重放；全部比较 CanonicalStateDigest，回放不追加原文或发送。
- 实际执行 `Owner.archiveFillHistory` 后重复成交，不增加费用或唯一应用量；恢复查询包含已有终态的未找到结果、无经济边界的结果、八项空查询和不支持资金费，另覆盖直接私有拒绝及再次断线。回放逐条比较完整 EventRecord，并保持核心交易权限关闭。
- Adapter 公共接缝覆盖 Unknown→拒绝重试→完整 raw 回放并逐字节比较重载检查点、仅上下文捕获失败的瞬态故障、原期限/权限在持久 capture 中失效、部分取消与 Reduce-only 的终态后迟到真实 Fill、REST/WS 重叠去重、背压/stop、超时、旧 session、资金费、容量、期限与预算不足。
- Standards / Spec 双轴审查发现并修复：私有拒绝回放缺失、归档/查询公开链路不足、发送上下文不足、拒绝重试误清 Unknown、查询结果未记录、持久捕获后的期限复核与瞬态上下文失败的状态重建。最终终态正面证据路径复审无阻塞。

### 实际验证

- Zig `0.17.0-dev.315+5b647b792`，Windows PowerShell。Debug：`python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig --test-filter Hyperliquid --stack 67108864`，最终 21/21 通过（`final-wave-stack-debug.log`）。同一入口追加 `-O ReleaseSafe`，最终 21/21 通过（`final-wave-stack-release.log`）。统一 verifier 的恢复验收标记也按这两份实际日志匹配通过。
- 新验收实际调用 `engine.applyStable` 的大状态副本，64 MiB 主栈首先触发溢出；已按仓库既有模式在测试内使用 512 MiB 独立工作线程，主入口仍以统一 verifier 的 64 MiB 配置验证。该调整只在验收代码，不改变生产线程或状态容量。
- 最后源码的完整 `zig build test -Doptimize=ReleaseSafe --summary all`：3/3 steps succeeded、868/868 tests passed（`verified-full-release.log`），包括既有 Venue、核心、安全、文件恢复与 native 合同回归。修正前一轮为 867/867（`full-release.log`），不替代最后结果；中间因发送与查询回放等新增回归暴露的失败均保留在日志中。最后一轮编译过程中停止了一次旧构建，以纳入上述 64 MiB 入口修正后重新运行。
- `zig fmt --check`、`git diff --check`、PowerShell verifier 语法解析通过。统一 verifier 已要求 Debug/ReleaseSafe 日志均含新增公开恢复验收标记；未额外执行整套性能/多进程 wave，不宣称其平台/容量资格。
- 日志与源码 SHA-256 清单位于 `.scratch/build/hyperliquid-06/`；所有私有消息均为合成离线输入，没有读取真实凭证或发送在线请求。

06 完成后仅将 07 设为下一 Frontier；不自动实施 07。真实 transport/注册、部署 epoch、全局额度与现有控制面接线仍由 07 完成；08 单独取得 Testnet 写入授权。历史/经济完整性不能证明的范围继续 pending，BTC/ETH 现货资产与市场条件、Testnet 和生产资格未取得。
