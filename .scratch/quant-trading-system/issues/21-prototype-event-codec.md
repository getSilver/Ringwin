# 原型验证事件编码与日志吞吐

Type: prototype
Status: resolved
Blocked by: 13, 19
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

最小的版本化事件头、payload 编码、分段日志和校验策略能否在开启真实校验与恢复扫描时满足容量和延迟目标？

## Answer

原型位于[事件编码与日志吞吐原型](../prototypes/event-codec/README.md)，使用 Zig 标准库且没有外部依赖。候选格式为 64 字节 segment header、56 字节 record header、变长 payload 和 32 字节提交 footer；所有整数使用小端稳定编码。record header 包含类型、schema 版本、flags、TradingShard 连续序号、source/receive/monotonic 三个时间戳、payload CRC32C 和 header CRC32C。解码器以总长度跳过未知类型或版本。

校验策略只保留 segment header CRC32C、逐记录 header/payload CRC32C、连续 shard sequence，以及包含记录数和末序号的 footer CRC32C。全 segment CRC32C 与这些检查的故障覆盖重复，实测还会使每个字节多扫描一次，因此不采用。

在 Windows、Zig `0.17.0-dev.315+5b647b792`、`ReleaseSafe` 下，以 70% × 32 B、25% × 96 B、5% × 256 B payload 连续运行四轮，每轮 2,000,000 个事件：

| 路径 | 中位吞吐 | 最低吞吐 |
| --- | ---: | ---: |
| 编码 + 记录头/payload CRC32C | 2.15 M events/s | 2.07 M events/s |
| 编码 + 顺序写 + flush + sync | 1.15 M events/s | 1.03 M events/s |
| 文件读取 + 完整恢复扫描 | 2.08 M events/s | 1.94 M events/s |

平均编码尺寸为 115.20 B/event。完整恢复、截断尾部恢复和单字节损坏检测全部通过。额外全 segment CRC 的对照结果只有 0.78 M events/s 写入和 1.07 M events/s 恢复扫描。

初步结论：格式与校验机制成立。按四个 TradingShard 均摊持续 2 M events/s，每个日志流需要 0.5 M events/s，本机单流最低 1.03 M events/s，具备约 2.06 倍吞吐余量。5 M events/s、持续 10 秒的均摊突发要求每流 1.25 M events/s，本机普通文件写入不能直接持续消化；必须由异步队列吸收，按最低实测约需暂存每分片 2.2 M 个平均事件，即约 253 MiB，随后排空。

这不是生产性能验收：本机没有 Debian 13、Linux 6.12、io_uring、预分配 segment、四日志流并发、CPU 隔离和真实 NVMe。生产资格测试必须验证四流总吞吐、10 秒突发后的队列水位与排空时间，以及交易核心仅执行 SPSC enqueue 时的 P99 延迟。

确认采用该候选格式和最小校验策略。当前原型验证通过的是编码、校验、顺序写入和恢复机制；Debian/io_uring 四流并发、突发积压与排空，以及 SPSC enqueue P99 延迟继续作为生产节点准入条件，不由本原型结果豁免。
