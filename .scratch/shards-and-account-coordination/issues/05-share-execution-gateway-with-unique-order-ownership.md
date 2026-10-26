# 05 — 共享 Execution Gateway 并保持订单唯一归属

**What to build:** 让四个 TradingShard 通过一个共享 Execution Gateway 和 VenueAdapter 外围层发送各自已合格的 OrderCommand，并以稳定 shard、order、command、revision 和 fencing identity 将逐项发送结果与 Venue 事实路由回唯一所有 shard；共享发送能力不能成为跨 shard 权威状态。

**Blocked by:** 01 — 冻结四分片共享账户协调协议

**Status:** resolved

- [x] 每个 OrderCommand 携带足以唯一定位 ExchangeAccount、TradingShard/DecisionDomain、order、command、revision 和 fencing generation 的身份；冲突、旧 fencing 或跨 shard order 引用在发送前失败关闭。
- [x] 共享 gateway 只拥有有界调度、限流和传输尝试，不拥有 OMS OrderState、reservation、经济归属或重试决定；所有结果通过目标 shard 的 apply seam 生效。
- [x] TransportBatch 的 NotSent、Submitted、Unknown 和逐项 definite reject 按原 command identity 返回唯一 shard；一个 item 的失败不会改变同 batch 其他 shard 的结果。
- [x] cancel、Reduce-only 和 KillSwitch 清理具有明确安全优先级，但不会绕过 per-shard revision、lease、账户 gate 或既有 CancelConfirmCreate 规则。
- [x] 四 shard 并发发送、单 shard 背压、批次部分结果、重复/冲突回报及恢复重放证明不重复发送、不跨 shard 改单且共享 Adapter 只有一份。

## Answer / implementation

- `Gateway.sendShardBatch` 沿用 `sendFromShard` 的共享资格校验与持久 DispatchProof，在最多四项、每 shard 最多一项的 turn 内，经同一账户唯一 VenueAdapter 发送 canonical `order_batch`。身份重复在任何持久或发送副作用前拒绝；优先级为 cancel（含 KillSwitch 清理）、Reduce-only、新增风险。
- 每项保留原请求位置及完整 command 身份，独立返回 NotSent、Submitted 或 Unknown。Venue 的逐项结果与 definite reject 由 Coordinator 经 wire client ID、原 command/order 绑定投递，经济变更仍由唯一 Owner.apply 完成。
- 本地结果经 `CoordinatorOwner.applyGatewayOutcome` 校验完整 command digest、目标归属、account scope、revision 和当前操作状态后进入 Owner.apply。重复 place 结果不回退终态；新 cancel/amend 不继承旧 place 的提交标记。
- 未确定尝试的 wire identity 可用于迟到事实路由，不授予重发权限。恢复仅还原证明；有未提交接受证明尾部时拒绝重新附着。背压的即时 NotSent 不构成自动重试许可，持久尝试仍保守保留 Unknown，直至显式对账。
- Adapter 请求显式区分 order 与 command identity；模拟与三家 Venue 的私有 order link 保留原订单身份，dispatch 仍返回原 command identity。Binance/Bybit 补齐绑定 namespace/account/order 的 wire client ID 回调与逐项回执 client ID；真实共享批次验证 command 3 撤销 order 1，不影响其他 shard。
- 验收、复审及完整套件的失败边界见 [05 验证报告](../05-validation-2026-10-26.md)。不继承 Venue 或生产资格；06、07 继续保持未完成。

## Closure (2026-10-26)

最终 ReleaseSafe 离线矩阵 **135/135**，覆盖 Coordinator、Gateway、四家 Adapter 与真实四 Owner 共享发送；Standards 与 Spec 双轴复审无剩余必修项。格式与 diff 检查通过。完整套件在第 87/800 项 cutover 测试栈溢出（前 86 项通过），未授予完整套件或生产资格；该边界由 07 收口。命令、逐条证据及限制见验证报告。
