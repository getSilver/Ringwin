# 验证四 Host、约百策略的容量与延迟

Type: benchmark
Status: closed
Blocked by: 06
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

四个 Host、约 100 个代表性中低频策略在正常、GC/异常、单 Host 落后和恢复负载下，
PythonDecisionLatency、吞吐、队列水位和核心干扰是否满足既定合同？

## Done when

- 每个权威分布至少 1,000,000 样本，报告 P50/P99/P99.9/Max、吞吐、队列与丢/拒绝数。
- PythonDecisionLatency P99 <= 50 ms、P99.9 <= 100 ms，且 stale/恢复意图为零。
- 一个 Host 的慢策略、GC、崩溃和恢复不使其他 Host 或 TradingShard 超出各自合同。
- Windows 只形成开发回归；约定 Linux 环境完成产品资格或明确记录未通过原因。

## Activity

- 2026-07-31：已认领；基准复用现有四进程 Host、冻结批次/SPSC 和标准库策略负载，
  每种权威分布固定至少 1,000,000 个决策样本并输出完整分位、吞吐、队列和拒绝计数。
  Windows 结果只作为开发回归，Linux 本轮仅验证可构建，不冒充产品资格。
- 2026-07-31：已关闭；新增 `strategy_host_capacity.zig` 与 Python `benchmark`
  模式，以每批 10 个 TimerEvent、每策略/事件一次回调定义决策样本；正常、
  GC/单策略异常、单 Host 变慢、Host 崩溃及恢复负载分别取得
  1,050,000–1,400,000 个样本。最差独立场景 P99/P99.9 为
  `16.5/33.75 ms`，与四分片并发时为 `19.5/29.85 ms`；所有场景
  input full、拒绝、stale 和恢复意图均为零，健康 Host 未越过 Python 合同。
- 2026-07-31：Windows 2C/4T 节点的四分片基线 P99 已为 `2.0345 ms`，
  并发慢 Host 时为 `8.2305 ms`，因此核心干扰的产品资格明确未通过；原因是
  不具备四个 TradingShard 专用物理核及外围 CPU。`x86_64-linux-gnu` 桥和容量
  程序交叉构建通过，但没有 Linux 运行节点，未授予 Linux 产品资格。完整原始结果
  位于 `benchmarks/07-windows-raw.txt`。
- 2026-07-31：回归通过：Python `py_compile`，IPC/lifecycle/failure 单元测试，
  lifecycle、交易接入、checkpoint 恢复与四 Host 故障矩阵真实进程验收。
