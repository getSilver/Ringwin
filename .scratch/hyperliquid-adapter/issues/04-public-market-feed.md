# 04：公共行情 Adapter

Type: task
Status: open
Assignee:
Blocked by: [02 共享领域合同](02-shared-domain-contracts.md)
Parent: [模块地图](../map.md)

## Question

如何让 Hyperliquid 公共市场事实经 MarketFeedAdapter 进入已有投影和策略输入，并准确保留有限覆盖与健康状态？

## What to build

在 `src/adapters/hyperliquid/` 实现独立公共行情生命周期，输出规范产品/规则观察、有限深度快照、市场成交、标记/指数价格、资金费率及健康事实。遵循 [深度合同](../../../docs/depth-snapshot-contract.md)，不绑定私有账户或凭证生命周期。

## 完成条件

- [ ] RawIngress 先捕获再解码；产品观察不自行激活规则或授予交易权限。
- [ ] 按当前每侧 8 档合同保留可见范围和截断，验证被截断尾部，不外推流动性、不伪造源序号；标记与指数价格不得互相替代。
- [ ] 非法帧、过期、断连、规则变化和重订阅使对应资格失效；新快照必须满足 session、时点与恢复合同，旧排队帧不能错误恢复健康。
- [ ] 订阅、队列、帧、重试与每轮工作有界，停机和背压不丢失必须提交的事实；不阻塞其他行情源。
- [ ] 通过 MarketFeedAdapter 公共接缝到核心投影及 Host 输入验证正常/非法/缺侧/重复/迟到/溢出/重连，重放结果一致。
- [ ] 注册适用共享契约及正式离线入口，记录 Debug/ReleaseSafe 结果；行情资格不宣称 maker 排队位置或成交概率资格。

## Answer

尚未开始。
