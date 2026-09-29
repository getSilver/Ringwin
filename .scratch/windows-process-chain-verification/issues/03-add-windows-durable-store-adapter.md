# 实现 Windows DurableStore 验证适配器

Type: task
Status: resolved
Assignee: grok
Blocked by: [01 冻结 Windows 验证合同与词汇](01-freeze-windows-verification-contract.md), [02 拆开 Binance/Bybit 能力证据并修正 wire 编码](02-split-binance-bybit-capability-evidence.md)
Parent: [Windows 进程链验证](../map.md)

## Question

如何让 DurableStore 在 Windows 上用真实文件完成 append/commit/snapshot/recover，同时明确这不是
Linux 目标文件系统的断电资格？

## What to build

在现有 `Store` seam 下增加 Windows 文件 adapter：三权限域 stream、manifest、提交同步、
同目录临时文件原子替换与恢复。调用方仍只提交 StreamIdentity、稳定 record、barrier 和 snapshot。
损坏、缺段、schema 不匹配进入 RecoveryOnly。journal/state schema 与现合同一致（14/15）。

Windows 同步使用 `FlushFileBuffers`（及等价目录更新）；不得宣称 power-loss 合格。Linux
`LinuxFileAdapter` 与 `--durable-store-test` 的 Linux 资格含义不变。

## Acceptance criteria

- [x] Windows adapter 通过同一 `Store` 接口；测试不接触文件名或 syscall。
- [x] raw_ingress、decision_log、control 分离；commit 返回前文件与 manifest 已刷新。
- [x] 快照临时写、刷新、原子替换；重开后 barrier、digest 与 snapshot bytes 一致。
- [x] 损坏、冲突、缺段、未知 schema 保持 RecoveryOnly 并关闭 SafetyGate。
- [x] `zig build` 提供 Windows 验收 step（或等价显式入口），输出标明 `adapter=windows_file`
      且 `power_loss_qualified=false`。
- [x] 生产票 03 不因本 adapter 关闭。

## Out of scope

- 目标 Linux 文件系统断电、io_uring、网络文件系统。
- 把 DurableStore 接到 TradingShard 发送路径（票 05）。

## Answer

- `WindowsFileAdapter` 复用同一 `Store` seam；文件 `File.sync` 走 `FlushFileBuffers`。
- `zig build windows-durable` 输出
  `adapter=windows_file` 且 `power_loss_qualified=false`。
- 生产票 03 仍为 ready-for-agent。
