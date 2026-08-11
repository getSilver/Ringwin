# 确定生产进程拓扑、CPU/NUMA 布局与内存预算

Type: grilling
Status: closed
Resolution: out-of-scope
Blocked by: 21, 22
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

在四个 TradingShard、四个 Python Strategy Host、异步行情/执行/日志外围以及单活热备约束下，首版单节点应采用什么生产进程拓扑、CPU/NUMA 亲和策略、线程职责和有界内存预算？

## Answer

当前阶段只形成产品原型的核心业务逻辑规格，不详细规划生产进程拓扑、CPU/NUMA 亲和、线程绑核和精细内存预算；这些内容在进入生产工程地图时重新评估。

## Comments

- 2026-07-29：因当前目标收敛为业务逻辑产品原型而移出本地图范围。
