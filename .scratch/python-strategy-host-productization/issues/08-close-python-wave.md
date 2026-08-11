# 形成可复现演示并关闭 Python 能力波次

Type: acceptance
Status: resolved
Blocked by: 07
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

哪些代码、命令、fixture 和性能/恢复证据足以证明 Python StrategyHost 已成为交易引擎的
产品能力，并可以进入真实 OKX Adapter 或 Linux 核心资格波次？

## Done when

- 新环境可自动运行正常、失败、恢复、重放和四 Host/百策略基准。
- README 明确产品协议、部署边界、已证明行为和未资格事项。
- 所有地图票据有证据，且 Python 不拥有权威交易状态、不绕过风险/OMS、不阻塞核心。
- SystemOwner 确认 Python 能力波次完成并选择下一波次。

## Activity

- 2026-07-31：已认领；验收将复用现有 Zig/Python 标准库命令形成一个跨平台、
  失败即停的自动入口，串联正常、交易接入、失败、恢复、重放和四 Host/百策略容量证据。
  本票只关闭 Python StrategyHost 能力波次，不把 Linux 性能资格或真实 Venue Adapter
  冒充为已完成。
- 2026-07-31：新增 `python/verify_strategy_host.py`，从仓库根目录以一条命令运行
  14 项格式、单元、真实进程和容量验收；父进程顺序收集子命令输出，任一步非零即停止。
- 2026-07-31：完整入口暴露并修复 IPC 自检冷启动竞态：测试子进程现在固定延迟
  75 ms、完成 bridge open 后发 ready，父进程才给批次打单调时间戳；生产 50 ms
  stale 合同未放宽。修复后的跨进程自检连续运行 10 次通过。
- 2026-07-31：最终 14/14 验收通过，输出
  `strategy_host_product_acceptance=passed`；权威记录位于
  `benchmarks/08-acceptance-windows-authoritative.txt`。README 已明确 Python
  不拥有权威交易状态、不绕过定点风险/OMS，以及真实 Venue 和 Linux 资格边界。
- 2026-07-31：修复后的 IPC 自检和容量入口均通过 `x86_64-linux-gnu`
  交叉构建；当前没有 Linux 运行节点，因此只声明可构建，不声明运行时性能合格。
- 2026-07-31：依据 SystemOwner 已确认的首批 Venue 顺序和当前产品原型优先级，
  选择 **OKX Venue Adapter 最小纵向接入** 为下一能力波次；Linux 专用核心性能
  资格继续作为独立后续波次。本票解决。

## Acceptance candidate

- [根目录 README](../../../README.md) 是唯一人工入口；
  `python python/verify_strategy_host.py` 是跨平台、失败即停的自动验收入口。
- 自动入口只编排现有产品 seam，不复制交易逻辑，不引入构建框架、RPC 或第三方依赖。
- IPC、生命周期、Gateway、PortableStrategyState、失败关闭和真实进程集成均有
  ReleaseSafe 检查；五种容量分布各自至少 1,000,000 个决策样本。
- Python 只拥有显式 schema 的 StrategyPrivateState，只能提交待核心复核的
  OrderIntent；权威订单、仓位、账本、风险、日志与 OMS 继续由 Zig TradingShard 拥有。
- Windows 结果只属于开发回归；真实 OKX 网络、密钥、testnet 和合格 Linux
  专用核心性能尚未资格化。

## Answer

- 2026-07-31，SystemOwner 的本次处理指令确认 Python StrategyHost 产品能力波次完成。
- 下一能力波次选择 **OKX Venue Adapter 最小纵向接入**；本票未创建或实现适配器。
- 完整复现命令、已证明行为和未资格事项以 [README](../../../README.md) 为准。

本地图验收完成。
