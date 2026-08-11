# 原型验证研究数据扫描、回放与目录发布

Type: prototype
Status: closed
Resolution: out-of-scope
Blocked by: 27, 29
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

在生产等价 Linux 研究节点和真实事件 schema 下，稳定事件段的八路 replay、Parquet + DuckDB 的交互 scan、SQLite catalog 并发与崩溃发布能否同时满足既定吞吐、延迟、新鲜度和原子可见性合同，应固定什么压缩、row-group、文件与资源参数？

## Answer

当前原型保留 SourceArchive、ReplayDataset 和确定性重放的业务契约，不验证生产研究存储的吞吐、压缩、文件布局和并发发布参数。

## Comments

- 2026-07-29：随原型范围收敛移出本地图。
