# 02：USDC 逐仓与必要共享合同

Type: task
Status: open
Assignee:
Blocked by: [01 协议与字段合同](01-protocol-field-contract.md)
Parent: [模块地图](../map.md)

## Question

如何让共享合同准确表达 USDC 线性逐仓和无源序号的有限深度快照，同时保持既有 Venue、经济事实及恢复语义？

## What to build

按 [ADR 0022](../../../docs/adr/0022-separate-margin-model-from-settlement-asset.md) 分离模型与结算资产；仅实现 01 和当前源码证明的共享缺口。复用既有资产、品种、行情和风险合同，不添加 Hyperliquid 专用核心分支。

## 完成条件

- [ ] USDT/USDC 使用真实独立 Asset，分别绑定规则、保证金、费用及损益；不得合并余额、固定汇率或跨资产抵押。全仓等未支持模式显式拒绝。
- [ ] 覆盖 Product、MarginModel、风险、经济投影与现有消费者；异资产不能混加，包装资产仅经批准建立经济配对。
- [ ] 捕获顺序与 Venue 连续性证据可区分；有限快照声明覆盖/截断，不能用本地自增数冒充交易所连续序号。
- [ ] 若有效价格规则不能由当前合同表达，补齐通用规则及验证；发送不悄悄修改已授权价格或数量。
- [ ] 列全 codec、journal、snapshot、digest、registry、fixture 和恢复校验影响；持久语义变化按版本合同处理，不能复用不兼容旧格式身份。
- [ ] 通过公共核心入口、编码与恢复测试验证正常、错资产、错规则、溢出、旧格式和快照失效；既有 Venue 与模拟实现明确支持或拒绝新语义。
- [ ] 记录实际 Debug/ReleaseSafe 及适用既有回归结果；纯命名变更或孤立模块通过不算完成。

## Answer

尚未开始，不代表当前代码已支持 USDC。
