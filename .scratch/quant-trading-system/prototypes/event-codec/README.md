# 事件编码与日志吞吐原型

> Throwaway prototype：只用于回答格式、校验和恢复扫描是否可行，不是生产日志实现。

## 问题

一个 56 字节小端版本化事件头、变长 payload、记录头与 payload CRC32C、连续分片序号和尾部提交标记，能否正确跳过变长记录、恢复截断尾部、检测损坏，并接近既定的 2M events/s 容量目标？

事件负载固定为 70% × 32 B、25% × 96 B、5% × 256 B。基准同时执行纯编码、普通文件顺序写入并 `flush + sync`、从文件读取并完整恢复扫描。

## 一条命令

```powershell
zig run -O ReleaseSafe .scratch/quant-trading-system/prototypes/event-codec/main.zig -- --events 2000000
```

本机工具链是 `0.17.0-dev.315+5b647b792`。生产构建必须固定精确 Zig 提交；Windows 普通文件 I/O 结果不能替代 Debian 13、Linux 6.12、io_uring、CPU 隔离环境的最终验收。

## 2026-07-27 本机结果

Windows、Zig `0.17.0-dev.315+5b647b792`、`ReleaseSafe`，每轮 2,000,000 个事件，四轮结果：

| 路径 | 中位吞吐 | 最低吞吐 |
| --- | ---: | ---: |
| 编码 + 记录头/payload CRC32C | 2.15 M events/s | 2.07 M events/s |
| 编码 + 顺序写 + flush + sync | 1.15 M events/s | 1.03 M events/s |
| 文件读取 + 完整恢复扫描 | 2.08 M events/s | 1.94 M events/s |

平均编码尺寸为 115.20 B/event。自检及四轮目标规模运行均通过完整恢复、截断尾部恢复和单字节损坏检测。

额外的全 segment CRC32C 曾使写入降至 0.78 M events/s、恢复扫描降至 1.07 M events/s。它与逐记录校验和连续序号提供的故障覆盖重复，因此从候选格式删除。
