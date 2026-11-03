# 05：订单与私有账户事实 Adapter

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 共享领域合同](02-shared-domain-contracts.md), [03 API 钱包凭证与签名](03-api-wallet-signing.md)
Parent: [模块地图](../map.md)

## Question

如何经既有 Gateway 发送首期订单集，并将私有结果准确转换为规范事实？

## What to build

实现固定绑定 Venue/环境/ExchangeAccount/session 的 VenueAdapter。支持限价 GTC/IOC、Post-only（ALO）、永续 Reduce-only、撤单与对账请求。原生 modify、触发单、TWAP、报价金额下单和自行定价市价单明确 Unsupported。

## 完成条件

- [x] 所有发送经 ExecutionGateway，保留授权、规则、能力版本、fencing 与期限复核；CLOID 通过纯编码扩展点准备并在发送前持久化。
- [x] trySend 接受不等于 Venue 接受；明确未发送、已提交和 Unknown。只在证明尚未写入时允许相应发送重试，不能重发未知订单。
- [x] RawIngress 成功捕获后输出 OrderDispatchResult、ExecutionReport、Fill 及账户观察；模式/杠杆事实由 Adapter 报告，配置目标和风险决策归既有控制面/核心。
- [x] IOC 零成交拒绝、部分成交后剩余量终结、ALO 拒绝、撤单成交竞争、迟到 Fill、重复和身份冲突分别验证。
- [x] report→fill 与 fill→report 经 applyAdapterBatch / TradingShard.apply 验证相同经济结果；OMS 累计量保持交易所状态，经济累计只计唯一已应用 Fill。
- [x] 费用、返佣、资金费和强平/ADL 按 01 映射到正确事实，不能伪造普通订单或把余额差当成交；不支持的事实保持安全失败。
- [x] 有界限流/队列/背压及 stop/drain 行为参加共享 VenueAdapter 契约；错误账户/session 与权限撤销不能发送，其他账户不被阻塞。
- [x] 用现有入口运行自身 Debug/ReleaseSafe、公开应用回归和适用共享检查，未完成恢复留给 06，不宣称上线资格。

## Answer

实现基线：`8eb5246cff672c4701f5d3a7b42841c639d34af6`；分支 `feat/hyperliquid-adapter`。
本票只取得离线实现证据，不授予 Testnet 写入或生产资格。

### 实现与边界

- [`HyperliquidVenueAdapter`](../../../src/adapters/hyperliquid/hyperliquid_venue_adapter.zig) 实现共享接缝。固定 Venue、共享环境、资金账户、签名 session、版本及品种/原子单位；真实 Testnet 配置要求已激活 InstrumentRegistry 与原生结算。共享 `Environment.demo` 在本实现对应 Testnet；真实钱包授权仅接受 signer 的 `.testnet`，没有主网发送组装。
- Gateway 的纯 CLOID 编码绑定 namespace/account/order，输出 `0x` + 32 hex，Gateway 原有持久发送记录负责先存后发。订单仅编码 Gtc/Ioc/Alo、永续 Reduce-only 和 cancelByCloid；每条命令独立发送，批次不声称外部原子性。MessagePack 与 JSON 的字段顺序、整数编码和精确十进制文本一致，已有签名器接收 MessagePack。
- `trySend` 的 accepted 只表示本地受理。明确未写入返回 not_sent；写入不确定、响应/来源 session 错误、原文捕获失败或无法证明订单余量的聚合响应返回 Unknown。Unknown 保留 CLOID/已证明 oid，阻止新增风险，不换 nonce 重发；迟到独立 Fill 仍可输出。REST filled 聚合不生成经济 Fill，部分 IOC/Reduce-only 聚合不伪造终态数量。
- `WalletAuthorization` 复用 Signer、CredentialStore 和 GatewayLeaseGuard。签名前后均保留会话/账户/fencing 检查，提交前再次检查期限与权限。撤单把既有 `increases_risk=false` 语义传到钱包签名入口，恢复模式仍拒绝新增风险签名；默认值 true 保留已有调用方行为。没有持久格式变更。
- REST/WS 原始字节先交给 RawSink，记录环境、资金地址、绑定/来源 session、路由、时点、长度与摘要；成功后才输出远端事实。捕获失败仅输出本地 Unknown 或 EconomicFault，不伪造远端成功。资金查询使用 funding 地址。orderStatus、clearinghouseState、spotClearinghouseState 请求实际经过只读 transport；查询结果始终 incomplete/unresolved，unknownOid 不证明不存在。
- orderUpdates 明确翻译状态、原量与余量；附加算法、触发/TP-SL/children、未知状态及矛盾的类型/TIF/Reduce-only 均失败关闭。Fill 用环境、资金账户、Instrument、time/tid/oid 的复合身份生成核心可接受的非零 u64 身份，比较规范内容并检查报告 PnL 冲突；不把内容 hash 加进业务键规避冲突。费用按真实激活 Asset，负值为返佣，零费用也必须有已知 Asset。非零 builderFee 因本期无 builder 授权而拒绝；不另加费用或重复记入 closedPnl。
- spot 余额必须同时匹配配置批准的 token index→Asset 与激活的 Venue code；缺 token 身份拒绝。tokenId 与 metadata 审批依据由 04/07 的已有配置路径拥有。逐仓杠杆输出规范配置观察；仓位/余额增量要求已有 bootstrap 引用，不自动建立完整账户快照。未知 abstraction/cross 模式安全失败，不从摘要估造可用逐仓资金、债务或交易权限。
- 资金费缺稳定 bill/revision 证据、强平/ADL/账务缺完整来源闭合时保留原文、输出 EconomicFault 并锁存本 Adapter 的新增风险；不生成普通 Order/Fill。非空 twapId 同样拒绝。
- 单实例保留一批待 drain 输出；输入帧最多 64 KiB、单帧最多 16 行、64 个订单及 128 个去重事实，满即失败关闭，不淘汰后重用身份。共享 egress Budget 最多 1200 weight/min，实际默认预算 100，exchange 单命令 weight=1、当前三个 info 查询 weight=2，保留撤单额度。该对象由单个运行 owner 串行驱动；跨进程/IP 与地址额度、真实 transport 的有界 pump、部署 epoch 由 07 接线，不声称本地桶证明全局限额。

### 验证

- 公开编码与 VenueAdapter 的 TDD 入口先记录缺实现失败，再逐切片通过；新实现实际调用 `venue_adapter_contract.exerciseWith`，覆盖背压/停机。协议与经济故障经共享 `exerciseEconomicFaultRecovery` 验证核心锁存、幂等和快照恢复。
- [`hyperliquid_execution_acceptance.zig`](../../../src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig) 经真实 Gateway 持久发送、DurableSink 捕获原文、Owner.applyAdapterBatch / TradingShard.apply 验证 report→fill 与 fill→report 的 OMS 累计、唯一经济累计、费用及完整 EconomicSummary 相等；重复 Fill 不改变 CanonicalStateDigest。每个 virgin Gateway 使用随机 namespace，因此不同运行的 CLOID 不同，未把跨运行审计摘要相等当作排列证据。Gateway 恢复保留 CLOID 且零发送。
- 此核心轨迹复用既有 USDT 离线权威夹具；独立现货用例另验证 `@11` / wire asset 10011 与激活的 USDC Asset 5 费用。以上均为合成样本，不代表指定 BTC/ETH Testnet 品种及真实资产资格。
- Zig `0.17.0-dev.315+5b647b792`，Windows PowerShell。最终 Debug：`python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig --test-filter Hyperliquid --stack 536870912`，15/15 通过（`final-debug.log`）。真实 CredentialStore：`python tools/zig-entry.py test src/security/credential_store.zig --test-filter 'Hyperliquid signer consumes' --stack 536870912`，2/2 通过，包括恢复模式撤单及旧 fencing 拒绝。
- 最终 ReleaseSafe：上述命令追加 `-O ReleaseSafe`，15/15 通过（`final-release.log`）。完整 `zig build test -Doptimize=ReleaseSafe --summary all`：3/3 steps、862/862 tests passed（最终源码日志 `verified-full-release.log`）。全套包含既有 Venue、核心及安全生命周期回归。`tools/verify-core-wave.ps1` 已加入新执行实现的离线标记，PowerShell 语法检查通过；未额外运行其整套性能编排。`git diff --check` 通过。
- 日志目录 `.scratch/build/hyperliquid-05/`。首次未指定大栈的独立测试发生栈溢出，后按既有核心测试容量指定 `--stack 536870912`；新增 USDC 夹具首次保留了缩小绑定数量后的多余条目，已按 Registry 合同清零，并通过最终 Debug/ReleaseSafe。早期运行不替代最终证据。

### 审查与后续

Standards / Spec 双轴审查已执行。Spec 首轮指出现货 token 与非首期订单类型两项 P1；已补配置绑定及公开接缝回归，复审无剩余阻塞。Standards 无实质阻塞。后续审查修正仍以最终源码和检查结果为准。

06 继续负责历史分页/覆盖、完整账户与经济对账、Unknown 闭合、恢复重载和 RawIngress/快照加尾部重放资格。当前 64/128 驻留上限、已存在 bootstrap 引用及配置批准的 token 映射不能充当恢复完整性。07 接入真实注册、批准配置、聚合限流与现有控制面；08 单独请求 Testnet 写入授权。05 不自动开始 06。
