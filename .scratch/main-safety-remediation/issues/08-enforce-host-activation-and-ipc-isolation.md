# 08: 以 HostActivated 和只读 IPC 强制策略隔离

Type: task
Status: resolved
Assignee: Codex
Blocked by: None (can start immediately)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让 StrategyHost 只有在应用权威 HostActivated barrier 后才能产生 OrderIntent，并使 Python 无法直接改写 input ring、游标或映射大小？

## What to build

把 HostActivated 作为 TradingShard 的不可变授权事实持久化并投影到 StrategyHostGateway。新会话默认无交易权限；Python 只通过 Zig supervisor 校验的 StrategyHostFramedBridge 收发自有 bytes，原始映射能力不进入子进程。Zig 内部 ring 仍保持有界和 sealed，但不再承担 Python 数据面。

## Acceptance criteria

- [x] Gateway 初始化和每次新 HostSession 都默认 trading disabled；只有持久化且已应用的 HostActivated 才能开放对应 StrategyActivationIdentity。
- [x] direct trade、recovery、strategy fault 和重启路径使用同一 activation barrier/cursor/config/digest 验证，屏障前输出一律拒绝。
- [x] Linux 内部 backing object 禁止 grow/shrink/seal 变更；子进程不获得 input/output backing capability，因而不能反向写 engine input。
- [x] Python 数据面不再传递 fd 或 mapping handle，argv 中不存在可预测 descriptor 数字，也没有多余 mapping descriptor 需要继承。
- [x] Python 不直接获得共享内存指针或原子游标，所有 input/output envelope、容量、session、sequence 和 cursor 校验由 Zig supervisor 独占。
- [x] hostile child 只收到约定 pipe/argv，Linux 运行时还会检查 `/proc/self/fd` 不含 `qsh-ring`；握手后 intent/confirmation 权限仍关闭。旧 session、旧 activation 和冲突 frame 继续 fail closed。当前 Windows 波次不宣称已运行 Linux `mmap`/`ftruncate`，Linux runtime 保持 `not_run`。

## Out of scope

- 把 Python StrategyPrivateState、解释器对象或业务交易逻辑迁入 Zig。

## Answer

HostActivated 已成为可重放分片事实；Python 仅通过 Zig 校验的有界 pipe 帧收发自有 bytes，不获得共享内存或游标能力。hostile-child acceptance 证明启动参数无 backing capability 且未激活权威权限，见 ADR 0007。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R08-A](../review-repair-plan-2026-09-23.md#08host-激活生命周期)要求故障、控制撤销与重启提交可重放的激活撤销，旧 StrategyActivationIdentity 即刻失效；追平后以新身份重新激活。TradingAuthorization 仍由独立事实判断。

## 2026-09-24 修复与离线验收

HostActivated 事实绑定非零 HostSession、激活身份、barrier 和状态摘要；Gateway 只从已应用且 journal 连续的分片事实开权，新会话必须撤销旧事实，同一会话不得重置批次序号。故障、控制暂停、退出和超时撤权可重放；旧身份立即拒绝，追平并以递增新身份激活后才恢复，TradingAuthorization 仍独立。direct trade、Gateway、snapshot/tail 与 StrategyHost 进程集成回归覆盖上述路径。Debug/ReleaseSafe 各 288/288；StrategyHost 14 步离线验证通过；journal/state schema 18/21。本票仅关闭离线安全缺口，Linux 目标运行和 Venue/生产资格仍为 `not_run`。
