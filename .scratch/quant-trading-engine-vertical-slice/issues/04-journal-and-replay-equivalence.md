# 接入稳定日志并证明重放等价

Type: implementation
Status: resolved
Blocked by: 03
Parent: [实现确定性交易引擎最小纵向闭环](../map.md)

## Question

如何将内存事件接入已验证的稳定版本化编码，使一次实时场景能够封存、扫描、重放并重建完全相同的 TradingShard 状态？

## Scope

- 从事件编码原型提取最小稳定 record/segment 契约，不复制基准驱动。
- 记录足以恢复状态的分片输入、决策和执行事实；展示日志不进入权威历史。
- 支持干净 footer、截断尾部恢复、CRC/连续序号失败关闭。
- ReplayDriver 只负责读取和注入事件；TradingShard 不增加 replay 专用状态转换。
- 首版快照仅在能明显缩短测试时加入，否则完整日志重放即可。

## Done when

- 实时运行与日志重放的事实序列和 StateDigestV1 完全相同。
- 截断尾部只恢复到最后完整提交记录。
- 单字节损坏、序号缺口和未知不可跳过的权威 schema 均失败关闭。

## Answer

- 新增 [`src/journal.zig`](../../../src/journal.zig)，从事件编码原型提取 64-byte segment header、56-byte record header、32-byte footer、逐记录 CRC32C、连续 ShardSequence 和稳定小端编码；未复制基准驱动或文件性能代码。
- 一次 happy path 封存为 31 条记录、2,351 bytes。每个 InputEvent 记录完整版本化 payload；同一输入同步派生的决策、命令和经济事实各占后续独立记录并保存稳定事实身份。
- [`src/main.zig`](../../../src/main.zig) 的 live driver 在唯一 `TradingShard.handle` seam 外写日志；ReplayDriver 解码并注入输入，然后逐条核对核心重新产生的类型、身份、时间和 ShardSequence。
- TradingShard 没有 replay 分支。实时运行与完整日志重放都产生 31 条相同事实及固定 StateDigestV1 `2d374b99264f82d6b218bff68a7f2ea81e9a1b26202849d5b39afc79eab2fabf`。
- 截断 footer 可恢复全部完整记录；截断最后一条记录只恢复到 ShardSequence 30。ReplayDriver 以候选状态应用一组输入/派生事实，尾组不完整时不会提交部分状态。
- 单字节 payload 损坏、记录序号缺口、未知权威 schema、无主派生事实、事实/时间不匹配均失败关闭。
- `zig test src/main.zig -O ReleaseSafe` 运行 happy path/replay 集成检查和稳定日志结构检查；`zig run src/main.zig -O ReleaseSafe` 输出 `replay=equivalent, recovery_checks=ok`。
- 首版不加入快照：31 条记录的完整重放已经足够小，快照当前不会明显缩短恢复或测试。

## Comments

- 2026-07-30：已认领；开始提取最小稳定日志并验证实时/重放等价及损坏恢复。
- 2026-07-30：稳定日志、完整重放等价、截断恢复及失败关闭检查全部通过；票据解决。
