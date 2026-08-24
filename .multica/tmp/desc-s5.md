来源：`.scratch/shards-and-account-coordination/issues/05-share-execution-gateway-with-unique-order-ownership.md`

**What to build:** 让四个 TradingShard 通过一个共享 Execution Gateway 和 VenueAdapter 外围层发送各自已合格的 OrderCommand，并以稳定 shard、order、command、revision 和 fencing identity 将逐项发送结果与 Venue 事实路由回唯一所有 shard；共享发送能力不能成为跨 shard 权威状态。

**Blocked by:** 01 冻结四分片共享账户协调协议

## 验收标准

- [ ] 每个 OrderCommand 携带足以唯一定位 ExchangeAccount、TradingShard/DecisionDomain、order、command、revision 和 fencing generation 的身份；冲突、旧 fencing 或跨 shard order 引用在发送前失败关闭。
- [ ] 共享 gateway 只拥有有界调度、限流和传输尝试，不拥有 OMS OrderState、reservation、经济归属或重试决定；所有结果通过目标 shard 的 apply seam 生效。
- [ ] TransportBatch 的 NotSent、Submitted、Unknown 和逐项 definite reject 按原 command identity 返回唯一 shard；一个 item 的失败不会改变同 batch 其他 shard 的结果。
- [ ] cancel、Reduce-only 和 KillSwitch 清理具有明确安全优先级，但不会绕过 per-shard revision、lease、账户 gate 或既有 CancelConfirmCreate 规则。
- [ ] 四 shard 并发发送、单 shard 背压、批次部分结果、重复/冲突回报及恢复重放证明不重复发送、不跨 shard 改单且共享 Adapter 只有一份。
