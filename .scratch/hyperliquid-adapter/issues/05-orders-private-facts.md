# 05：订单与私有账户事实 Adapter

Type: task
Status: open
Assignee:
Blocked by: [02 共享领域合同](02-shared-domain-contracts.md), [03 API 钱包凭证与签名](03-api-wallet-signing.md)
Parent: [模块地图](../map.md)

## Question

如何经既有 Gateway 发送首期订单集，并将私有结果准确转换为规范事实？

## What to build

实现固定绑定 Venue/环境/ExchangeAccount/session 的 VenueAdapter。支持限价 GTC/IOC、Post-only（ALO）、永续 Reduce-only、撤单与对账请求。原生 modify、触发单、TWAP、报价金额下单和自行定价市价单明确 Unsupported。

## 完成条件

- [ ] 所有发送经 ExecutionGateway，保留授权、规则、能力版本、fencing 与期限复核；CLOID 通过纯编码扩展点准备并在发送前持久化。
- [ ] trySend 接受不等于 Venue 接受；明确未发送、已提交和 Unknown。只在证明尚未写入时允许相应发送重试，不能重发未知订单。
- [ ] RawIngress 成功捕获后输出 OrderDispatchResult、ExecutionReport、Fill 及账户观察；模式/杠杆事实由 Adapter 报告，配置目标和风险决策归既有控制面/核心。
- [ ] IOC 零成交拒绝、部分成交后剩余量终结、ALO 拒绝、撤单成交竞争、迟到 Fill、重复和身份冲突分别验证。
- [ ] report→fill 与 fill→report 经 applyAdapterBatch / TradingShard.apply 验证相同经济结果；OMS 累计量保持交易所状态，经济累计只计唯一已应用 Fill。
- [ ] 费用、返佣、资金费和强平/ADL 按 01 映射到正确事实，不能伪造普通订单或把余额差当成交；不支持的事实保持安全失败。
- [ ] 有界限流/队列/背压及 stop/drain 行为参加共享 VenueAdapter 契约；错误账户/session 与权限撤销不能发送，其他账户不被阻塞。
- [ ] 用现有入口运行自身 Debug/ReleaseSafe、公开应用回归和适用共享检查，未完成恢复留给 06，不宣称上线资格。

## Answer

尚未开始。
