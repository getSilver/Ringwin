# 拆开 Binance/Bybit 能力证据并修正 wire 编码

Type: task
Status: resolved
Assignee: grok
Blocked by: [01 冻结 Windows 验证合同与词汇](01-freeze-windows-verification-contract.md)
Parent: [Windows 进程链验证](../map.md)

## Question

如何在没有 Testnet 密钥、也不宣称 `TestnetQualified` 的前提下，停止把未验证的 Binance/Bybit
订单能力写成已经具备的事实？

## What to build

把 CapabilityProfile 中的目标 required capability 与当前 verified evidence 分开。未经过真实
transport/Testnet 的 `native_amend`、`native_post_only`、`bounded_batch` 不得出现在已验证投影。
Binance Spot/永续按官方 HTTP method、path、参数位置和签名输入编码；删除或隔离通用
`operation` 字段对 wire contract 的冒充。Transport 保持可注入，资格状态保持 `not_run`。

## Acceptance criteria

- [x] 支持矩阵或等价结构同时存在 required 与 verified；verified 在无真实运行时为空或 `not_run`。
- [x] Binance Spot 与 USDT 线性永续的 place/amend/cancel 编码有针对官方路径的契约测试；通用
      `operation` 不得作为 Binance 请求体的权威字段。
- [x] Bybit 保持可注入 transport 与官方路径编码；不引入 Demo/Testnet 活运行。
- [x] 离线 `zig build test` 覆盖上述契约；任何资格输出中 Binance/Bybit 仍为 `not_run`。
- [x] [生产票 06](../../production-readiness/issues/06-qualify-binance-linux-online-chain.md) 与
      [07](../../production-readiness/issues/07-qualify-bybit-linux-online-chain.md) 不得因此
      标为 resolved。

## Out of scope

- Binance/Bybit 真实 REST/WSS、密钥、Testnet 下单、清理闭环与 `TestnetQualified`。
- 把这两家 adapter 接到 Windows 验证进程链。

## Answer

- `SupportMatrixEntry` 增加 `verified_capabilities`（空）与 `qualification=not_run`。
- Binance/Bybit `CapabilityProfile` 增加 `verified_*`（默认 false）与 `qualification=not_run`。
- Binance wire：Spot POST/DELETE `/api/v3/order`、amend POST `/api/v3/order/cancelReplace`；
  线性永续 POST/DELETE/PUT `/fapi/v1/order`；form 编码，无 `operation` 字段。
- 生产票 06/07 仍为 ready-for-agent / paused。
