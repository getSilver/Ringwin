# 形成可复现演示并关闭产品原型阶段

Type: acceptance
Status: resolved
Blocked by: 07
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

哪些代码、命令和证据构成一个可由新环境独立复现的交易引擎产品原型，并足以进入真实 Venue Adapter 与 Python 策略接入阶段？

## Scope

- 提供构建、运行全部 acceptance traces、实时后重放及基准的最少命令。
- 输出事件数量、终态摘要、账本闭合、重放等价和性能分布。
- 区分已证明的产品行为、仅在 Windows 验证的开发结果和仍需 Linux/testnet 资格的事项。
- 删除 throwaway glue、未使用抽象和调试入口；保留必要 fixture 与检查。
- 形成下一阶段地图，只包含真实 Venue Adapter、Python StrategyHost 接入和生产工程中实际尚未解决的问题。

## Done when

- 从干净环境按文档命令可以自动得到相同功能验收结果。
- 所有本地图票据均有可追踪证据且不存在未声明的关键业务旁路。
- 用户确认产品原型闭环完成并选择下一能力波次。

## Activity

- 2026-07-30：已认领；开始整理干净环境复现入口、证据索引、范围边界与下一能力波次候选。
- 2026-07-30：根目录复现文档、显式演示摘要和全部功能/性能入口已在当前环境逐条验证；等待 SystemOwner 确认闭环并选择下一能力波次。
- 2026-07-30：SystemOwner 确认闭环完成并选择 Python StrategyHost 产品化接入；创建下一阶段地图，本票解决。

## Acceptance candidate

- [根目录 README](../../../README.md) 是新环境唯一复现入口，固定 Zig
  `0.17.0-dev.315+5b647b792`，列出格式、ReleaseSafe 测试、ReleaseSafe 演示、
  单分片 ReleaseFast 基准和四分片 ReleaseFast 基准的最少命令。
- 产品代码只有 [`src/main.zig`](../../../src/main.zig) 与
  [`src/journal.zig`](../../../src/journal.zig)，仅依赖 Zig 标准库；历史
  `.scratch/quant-trading-system/prototypes` 不在产品构建路径。
- 演示现在显式输出 happy path 的 31 条事实、订单终态、定点成本/费用/PnL、
  风险余额、`ledger=closed`、日志记录数、恢复检查和 StateDigestV1。
- `zig test src/main.zig -O ReleaseSafe` 自动执行三项检查：全部权威轨迹及重放、
  四分片重放/过载隔离，以及稳定日志损坏/截断/序号检查。
- README 分开列出已证明行为、仅在 Windows 测量的开发结果、尚需 Linux/testnet
  资格或尚未实现的能力；没有把 Windows 数字表述为生产资格。
- 下一阶段只建立
  [Python StrategyHost 产品化地图](../../python-strategy-host-productization/map.md)；
  真实 OKX Adapter 和 Linux 五核资格仍是后续独立 Destination。

## Answer

- 2026-07-30，SystemOwner 明确确认交易引擎产品原型闭环完成。
- SystemOwner 选择 **Python StrategyHost 产品化接入** 作为下一能力波次。
- 干净环境复现入口、功能摘要、Windows 开发性能证据和未资格化边界继续以
  [README](../../../README.md) 为准。
- 下一能力波次由
  [产品化接入 Python StrategyHost](../../python-strategy-host-productization/map.md)
  单独承载；真实 Venue Adapter 与 Linux 五核核心资格不混入该地图。

本地图验收完成。
