# 09 Spec review

基线 `0779b48ec7a6f91e989f6d3c68049d0b012ff3dc`；2026-10-16复核当前工作树，含三份新增 continuous acceptance 及更新的 observation/OMS 检查。仅审查，未运行测试或修改源码。

## (a) 缺失／部分要求

无剩余确认 P1/P2。先前“三策略类别未实质区分”的 P2 已由当前源码补齐：issue09:19 的“三个策略类别的合成意图”及 capacity-contract:29–30 的资金费双腿／跨路由分别风控，现在由 `src/core_observation_capacity_acceptance.zig:185` 的真实 spot-long/perpetual-short、route0-long/route1-short 意图与其余 selected quotes 覆盖；`:555` 校验各腿独立完整风险引用、正占用、账户与品种，`:579` 实际 Gateway 派发／Fill，`:604` 恢复 signed position 与完整摘要，`:639` 核对 product、base、归一数量和 Venue/account。四 Owner 共100 live／4 terminal，没有新增规模负载。

双腿开平与单独 hedge 另由 `src/continuous_capacity_acceptance.zig:387` 公共 Owner/Gateway/Fill 链覆盖；该夹具不冒称资金费算法或跨所原子交易。结合上述类别 fixture，满足当前小规模合成意图范围。

## (b) 多余范围

未确认。Summary 扩至 u16、独立 snapshot9／digest9／publish type14 并拒绝旧 type1，属于计数边界修复；不要求无关 Core schema 同升。OMS total/full/over 的 `>=` 及纯数值断言连接真实生产路径，符合 issue09:20。

## (c) 看似实现但错误

未确认 P1/P2。四片十轮已有非零 Fill／账本并恢复完整摘要，归档 accepted 证明在恢复前后认证重试均断言零发送。mixed 当前5 live／3 terminal，Unknown 与 PendingCancel 共存；独立 backpressure 链覆盖真实 accepted→Unknown 恢复、输入重试、安全事实继续处理及占用保留。

观察证据为新夹具500 Owner-local投影／494独立组合，加现有 observation 夹具真实 unique500；不能称新夹具 unique500。最终 Debug/ReleaseSafe、源码冻结、资源样本和 artifact 审计仍待实际结果；现有开发检查或本静态结论不代替最终验收，不授予千单／压力／资源预算／平台资格。
