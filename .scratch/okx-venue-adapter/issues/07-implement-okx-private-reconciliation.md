# 接入 OKX 私有事实与启动重连对账

Type: task
Status: resolved
Assignee: Codex
Blocked by: 01, 02, 03, 04, 05
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何通过 OKX Demo 私有 WebSocket 与 REST bootstrap/reconciliation 生成可去重的 ExecutionReport、Fill、ExchangeBalanceSnapshot、ExchangePositionSnapshot、ExchangeMarginSnapshot 和 VenueAccountConfigurationSnapshot，并在启动、断连、分页、迟到及冲突事实下只在完整解释后恢复新增风险？

## Answer

新增 `src/okx_private_reconciliation.zig` 作为固定 OKX 私有事实与恢复屏障。transport owner 只提交完整 JSON、来源 session、三类私有订阅 ACK、既定时间和逐端点分页状态；模块在任何解析前写 RawIngress，并在完整解释前缓存所有 CanonicalEvent，不向 TradingShard 开放新增风险。

- 私有流只有在 `orders/account/positions` 三个订阅 ACK 以及 account、positions 全部分页初始 snapshot 完成后才进入 buffering；orders 明确不等待不存在的初始 snapshot。
- REST bootstrap 固定覆盖 account config、逐仓杠杆、显式余额、仓位、pending orders、SPOT/SWAP orders history 与 fills history。订单页以 `ordId`、成交页以全局 `billId` 驱动 `after`，游标直接从原始行取得，不受事实去重影响。
- OKX 没有跨 REST/WS 原子 watermark，因此屏障执行“先订阅并缓存 -> 全 REST 读 -> 再次全 REST 稳定读 -> REST 事实先排空 -> WS 事实后排空”。两轮任一端点原始 digest 不同、未解释 Unknown、未归属活动订单、冲突事实或断线都不会打开或保持 `ReconciliationReady`。
- ExecutionReport 以 `ordId` 为订单主键；terminal 回报按 `ordId+state` 幂等，非 terminal 回报加入累计成交、价格、`reqId/tradeId` 业务字段，忽略可变化的 `uTime`。Fill 以 `(instId,tradeId)` 去重，并保存 REST `billId` 交叉证据；负 tradeId 可保真。相同身份不同内容失败关闭。
- balance 与 margin 从同一 account observation 生成并共享 raw evidence；空字符串保留为 absent，不与数值零混淆。position 保存 `(instId,mgnMode,posSide)` 领域字段与可重建的 `posId` incarnation。配置、余额、margin、仓位及杠杆 snapshot 也按确定性内容哈希去重。
- `tools/okx-demo-private-readonly.ps1` 只登录 Demo private WS 并订阅 orders/account/positions，输出 ACK、snapshot 行数和 `writes_sent=0`，不打印事实值或凭据。当前开发节点对官方 `wspap.okx.com:8443` 的 TLS/网络握手被拒，故本票不宣称在线 private WSS 资格；票 11 必须在可达节点重跑并留存资格证据。

验证：`zig test src/main.zig` 共 18 项通过，覆盖 RawIngress 优先、初始 snapshot 门槛、九端点两轮稳定屏障、REST-before-WS drain、语义重复订单及断线撤销就绪；既有权威回放与公共行情测试保持通过。只读 REST Demo preflight 再次通过，未发送订单、撤单或账户写请求。
