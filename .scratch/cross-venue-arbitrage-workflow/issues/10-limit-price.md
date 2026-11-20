# 10 让策略限价准确到达 Gateway

Type: task
Status: resolved
Assignee:
Blocked by: 无
Parent: [模块地图](../map.md)

## Question

最终发给场所的限价是否等于策略按规则选定的价格？

## What to build

以同一版本的 InstrumentRules 在策略、Host、TradingShard 和 Gateway 间精确传递限价。

## 验收条件

- [x] 价格 100、tick 0.01 的 10,000 ticks 在 Gateway 最终请求中等于 100。
- [x] 经正常 Host 输出验证单腿及双腿，覆盖两腿不同 tick。
- [x] 无法精确表达时拒绝发出该请求，报告对应腿与单位原因。

## Answer

普通 Host 输出逐腿携带限价 ticks、InstrumentRules 版本与精确十进制 tick。TradingShard 按各账户当前结算资产精度校验 tick 单位，再以原 ticks 授权。规则版本、tick 单位或价格精度不符时，记录对应意图序号及拒绝原因。组内任何一腿未通过价格校验时，整组没有生成命令。

离线 Gateway 捕获到单腿 SPOT IOC 请求，单腿稳定日志通过重放。双腿请求分别为 10,000 × 0.01 = 100 和 4,002 × 0.025 = 100.05。第二腿规则版本失配、tick 单位失配及价格小数精度超限均有定向拒绝回归。真实 Python Host 公共盘口场景经 TradingShard 到 Gateway 捕获两腿 IOC 请求，并验证持久恢复。

验证使用定向 Zig 测试、公共盘口专用集成入口和相关 Python 测试。数据来自离线夹具，下一张业务里程碑仍按 [11](11-dual-ioc.md) 的阻塞关系推进。
