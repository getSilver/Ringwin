# 把 fixture 形状的 TradingShard 深化为产品核心模块

Type: task
Status: resolved
Assignee: Codex
Blocked by: 01
Parent: [完成交易核心系统闭环](../map.md)

## Question

如何在不建立第二套核心的前提下，把当前 `src/main.zig` 内由固定 Genesis 和单一品种驱动的 TradingShard 深化为小 interface、显式依赖、可配置但有界的产品模块，使原生策略、Python StrategyHost、SimulatedVenue、OKX 和重放都只穿过同一 seam？

## Answer

TradingShard 已从 executable fixture 提取为唯一产品模块，外部以版本化 CanonicalEvent 调用 `apply`，获得有界不可变 facts 和可选 OrderCommand；`main` 只保留组装与运行入口，不再拥有权威状态机。

Genesis 的 InstrumentRules、MarginRules、ExchangeAccount、余额、VirtualPortfolio、资金划拨、Strategy activation、PrimaryLease 与 RiskLease 均改为显式、有序且版本化的规范事实。缺失、乱序、重复或身份不匹配会失败关闭；完整配置及其容量语义进入当前 CanonicalStateDigest，并可由稳定日志确定性重放。

原生策略与 Python StrategyHost 现在使用同一 OrderIntent 权威校验和风险路径。SimulatedVenue 与 OKX 只消费 OrderCommand，并将逐项 submitted/unknown 结果作为规范输入返回 `apply`；独立 ReplayTradingShard 类型不持有发送 interface。现有 OKX spot 经济投影暂不迁移，按地图由后续经济闭合票收回同一核心。

ReleaseSafe 与 ReleaseFast 各 52 项测试通过；五条离线成功/故障轨迹均锁定新的 V2 摘要并保持 live/replay 等价。
