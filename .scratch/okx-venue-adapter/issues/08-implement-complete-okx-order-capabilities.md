# 落实既定 OKX 订单能力与有界调度

Type: task
Status: resolved
Assignee: Codex
Blocked by: 01, 02, 03, 04, 05, 07
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何在既有 OrderIntent、RiskDecision、OrderCommand 与 CapabilityProfile 契约下实现 OKX SPOT/SWAP 的 Limit、Market、GTC、IOC、FOK、Post-only、VenueReduceOnly、原地 amend、获授权 CancelConfirmCreate、非原子 TransportBatch、版本化规范化、限流优先级、稳定错误、发送结果与 Unknown 对账，同时继续执行全部已确认的禁用项？

## Answer

新增 `src/okx_order_entry.zig`，把已经由 OrderIntent/RiskDecision 冻结的规范 OrderCommand 转成固定 OKX REST order item，并在同一深 module 内完成版本 gate、有界调度、逐项 ACK 分类及替代单安全门槛。VenueAdapter 四操作 seam 不变，TradingShard 不接触 endpoint、JSON 或 OKX code。

- CapabilityProfile 固定适用的 capability/rules/config/GatewaySession、Demo 资格、Limit、受保护 Market、IOC、FOK、原生 Post-only、原地 amend、SWAP VenueReduceOnly、single/batch/sub-account 限流与 batch 上限。任一版本漂移、OrderRevision/累计成交陈旧、风险占用无效或 OrderEntryReady 未成立均在触网前形成稳定 NotSent。
- 首波只生成 REST `order/batch-orders`、`amend-order/amend-batch-orders` 和 `cancel-order/cancel-batch-orders`；不为 WS 写入再维护一套 `instIdCode` codec。SPOT 使用 `cash`，SWAP 固定 `isolated + net`；VenueReduceOnly 只允许 SWAP 并显式编码。
- Limit/GTC、IOC、FOK、Post-only 直接映射 OKX `ordType`。为执行不可降级的价格保护，规范 Market 必须已经带风控冻结的保护价，并编码成一次 `ioc + px`；不能证明保护时拒绝，不发送裸 SWAP Market。codec 强制 `pxAmendType=0`，amend 强制 `cxlOnFail=false`。
- `RWN1` client order ID 与 `RWA1` amend request ID 使用完整 `u128` 领域身份的 base36 编码，纯字母数字、最多 30 位、确定且不截断；真实 codec 不再使用不符合 OKX 合同的连字符。取得 ordId 后 amend/cancel 同时携带 ordId 与永久 clOrdId。
- Amend 输入仍是 TargetRemainingQuantity，codec 在已确认累计成交屏障上计算 OKX 要求的 total `newSz`；旧 revision 或累计成交变化即 NotSent/StaleOrderRevision。CancelConfirmCreate gate 只允许“精确 cancel -> 权威终态/Unknown 对账 -> 重新风控”，不会重叠下新单、复用旧身份或自动撤单。
- 普通队列 64 项，安全队列 32 项；Cancel、VenueReduceOnly 和降风险 amend 使用独立安全容量。批内按 deadline、ShardSequence、CommandIdentity 稳定排序，只合并同 operation/product/instrument/session/version 的已排队命令，不等待凑批；安全 burst 上限 8，避免无限饿死普通命令。
- single 与 batch 的 place/amend/cancel 桶分别计数，batch 按 item 数计费，并叠加 sub-account place+amend 桶。完整逐项 `sCode=0` 是 Submitted；明确逐项 venue reject 仍是 Submitted 加稳定 CanonicalRejectReason；写后断连、timeout、损坏/缺项响应全部逐命令 Unknown，禁止整批或单项自动重放。
- 继续禁用组合 cancel-replace、`cxlOnFail`、重叠式撤旧建新、适配器二次规范化、无授权 FOK 降级、静默 TIF 改写、按 Instrument cancel-all 和交易 POST 自动重试。

验证：`src/main.zig` 导入后 Debug、ReleaseSafe、ReleaseFast 各 26 项全部通过，`x86_64-linux-gnu` 交叉编译通过；覆盖全部 order kind 编码、Market 保护映射、身份 codec、版本/期限/背压、single/batch/sub-account 限流、安全优先与公平性、逐项部分成功、Unknown 和 CancelConfirmCreate。此票未启用 `--demo-live`，未发送任何 Demo 订单；真实 libcurl 发送与 Demo 成交闭环由后续票完成。
