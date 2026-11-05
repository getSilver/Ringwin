# 07 核实并补齐 ManagedHost 有界等待

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: ready-for-agent
Evidence level: Windows 真实受控子进程反例与 ReleaseSafe 定向通过；模块全量失败另行跟踪

## Question

握手、输出、checkpoint 和 shutdown 的实际 I/O 是否受生命周期时限驱动，并在超时后撤权？

## Problem Statement

HostSupervisor.poll 有超时状态机，ManagedHost 接收及 shutdown 却可阻塞在 pipe 读取或 child.wait。
部分 Windows verification 同步等待。Python package 路径已有外层 watchdog，不能把所有调用都判为无保护。

## Solution

逐调用方核对期限与取消所有者，对未受实际保护的路径补齐有界等待及既有故障撤权，保留正常 Host 行为。

## User Stories

1. 作为策略所有者，我希望挂起 Host 只影响规定范围，以保持其他 Host 与核心进展。
2. 作为运维人员，我希望握手有上限，以免错误进程永久占据启动流程。
3. 作为运维人员，我希望半帧也会超时，以免少量字节无限延长等待。
4. 作为安全负责人，我希望超时撤销旧激活权限，以拒绝迟到输出。
5. 作为运维人员，我希望 shutdown 有界，以免依赖子进程自愿退出。
6. 作为控制面操作者，我希望独立控制进展继续，以免阻塞吞掉停止请求。
7. 作为维护者，我希望准确识别既有 watchdog，以免重复建设。
8. 作为恢复执行者，我希望重建使用新 session 并重新激活，以免复活旧许可。

## Implementation Decisions

- 列出真实调用方、外层 watchdog、I/O 取消机制、时钟与撤权路径，先证实具体缺口。
- 复用 HostSupervisor、ManagedHost 与匿名 pipe framing，不引入共享内存或另一个 Host 管理器。
- 未保护路径统一等待、期限、退出与取消；不能要求调用方在永不返回的读取之后才 poll。
- 超时沿既有 Host fault/SafetyGate/激活失效处理；迟到帧按原 session/activation 合同拒绝。
- 保持单一读者及帧所有权，取消不能丢帧、重复消费或同时发布成功与超时；平台实现据实际能力确定。

## Testing Decisions

- 由 ManagedHost 启动真实受控子进程并走实际调用方，不能只人为调用 poll 推进时钟。
- 覆盖无输出、只写长度/半帧、停止读输入、输出后不退出及正常响应。
- 覆盖握手、batch ACK、输出、checkpoint、shutdown；测试独立外层清理预算避免自身挂死。
- Windows verification 与 Python package 已有保护分别核对，Linux 支持路径独立记录。
- 验证撤权、旧帧拒绝、资源回收和不相关控制进展，正常流不得重复消费或误杀。

## Acceptance Criteria

- [x] 完成逐调用方时限/取消/撤权责任矩阵，既有 watchdog 路径不误报。
- [x] 真实挂起子进程在产品既有预算内结束等待或失败；测试外层 watchdog 不能冒充产品超时成功。
- [x] 确有缺口时修复实际 I/O 路径，超时沿既有机制撤权，旧 session/activation 输出拒绝。
- [x] 半帧、阻塞写和等待退出有明确处理，无双读、泄漏或成功/超时竞态。
- [x] 不相关控制进展和正常生命周期有正例；不能证明的路径明确未完成。
- [x] 适用平台的最小定向集成验收有证据；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行；排除风险需实际调用链和实验反证。

## Out of Scope

重写 Host 协议、新调度框架、在线交易、平台生产资格。

## Further Notes

遵守 ADR 0007/0021，按当前源码核对已有 package watchdog，不能沿用旧票关闭结论。
来源见[审阅证据](../evidence.md)。本次仅发布规格，未执行挂起实验或修复。

## Answer

2026-11-04 实施，2026-11-05 完成定向及最终结果记录，07 resolved；模块仍 open。按当前调用链核实 R2，确认共享 ManagedHost 的同步 pipe 读写及等待退出没有实际 I/O 时限；Python package 已有独立外层 watchdog，不将其误报为全路径无保护。

### 调用方及责任矩阵

| 实际调用方 | 原有保护与缺口 | 本次期限、取消及故障归属 |
|---|---|---|
| `strategy_host_lifecycle.integrationChecks`；三个 `strategy_host_*_integration`；`strategy_host_capacity` | Supervisor 可人工 poll；`verify_strategy_host.py` 逐个 subprocess.run 没有 timeout，不能保护阻塞 read/write/wait | ManagedHost 对实际 I/O 使用 awake 时钟固定截止点；完整前缀、帧、分段写共用预算。显式 crash wait 改走 `waitForExit`；测试所有者 defer 回收 |
| Windows verification `runRole` 的 OKX Host、`EngineOwners.start/exercise` | 直接调用共享 ManagedHost；无独立 Host pipe watchdog，try 失败向 runRole 返回 | 相同 I/O 时限；超时标记 failed，取消并 join 唯一 I/O，再清理拥有的 child。runRole 的 host/owners defer 继续负责退出清理；不宣称已实测其 durable Host fault 撤权 |
| `strategy_candidate.Instance.initialize/execute` | `strategy_instance.CandidatePipes` 已有队列读超时、写完成预算；InstanceManager 用单调 callback/warmup 预算、Windows Job/Linux process group 终止和实例失权；`_outside_lock` 保持其他 Host/Web 操作进展 | 保留原外层预算；内部生命周期预算设在外层 manifest 预算之后作为兜底。Instance 借用同一 child，`owns_child=false`，取消 join 后返回错误，由唯一进程所有者和原 package watchdog 清理，避免重复关闭复制的句柄 |
| candidate 主循环 `awaitCommand/awaitHostExit` | 已用 Select 竞争，execute 前 cancel/join，命令空闲等待由 backend/InstanceManager 终止 | 保留既有单读者与所有权，不另建 Host manager；不把空闲命令等待误记为 callback 挂起 |

Linux production role 未接线 ManagedHost；Linux package 走相同候选代码及既有 process-group watchdog。交叉编译通过只证明可编译，Linux 原生 pipe 取消/回收仍未验。其他 role 的 named-pipe/socket/进程编排等待不属于本票 StrategyHost I/O 修复。

### 修复与证据边界

- 源码基线 `3781870cd08153fb0c7b50a2347133d26ce158ec`；实现提交 `c2c0ad62`，退出等待补修及冻结源码 `f9e85144847527b9459c47049874a746dd4c5480`。源码文件 SHA-256、平台及工具版本见 `.scratch/build/source-audit-07-source-identity.txt`；本地 tracker 保持未跟踪状态，提交不包含其余规格。
- 新真实子进程反例先失败：配置 300ms startup，原 read 一直等待到夹具 10s 独立清理才返回 EndOfStream。该外层清理导致的失败不算产品超时。修复后返回 HostTimeout，Supervisor failed，拥有的 child 回收；关闭后的句柄不会再次解引用。
- `Io.Select.concurrent` 竞争实际读写/进程 wait 与绝对 deadline。返回前 cancel/join；无后台第二读者，不复用半帧，不延长慢速零碎字节的截止点，不同时发布成功与超时。I/O 错误/取消同样失败关闭。shutdown 的写、ACK 和进程退出共用一个 grace；ACK 后不退出也会失败并终止。
- input batch 写及输出/ACK 共用预算；checkpoint 请求写及响应共用预算。合法成功帧仍经原 session、sequence、容量、CRC 与 payload 校验；没有更改 framing、checkpoint schema、权威 codec 或 digest，不需要格式升级。
- 真实受控子进程覆盖 silence、仅长度、半帧、慢速字节、batch ACK 缺失、输出缺失、checkpoint 不返回、停止读输入、shutdown 不 ACK、ACK 后不退出。挂起操作并发期间另一真实 Host 正常 shutdown，验证独立生命周期控制可进展。
- 输出/ACK 超时回归随后显式调用既有 `revokeHostAuthority`：核心 activation 清零，旧 activation 输出被 Gateway 拒绝；故障 ManagedHost 再次读取返回 InvalidState。此为已确认共享业务 seam 的撤权证据，不等于执行了 Windows runRole durable 故障注入。
- 正常流复用既有 lifecycle、输出和恢复集成；新进程代次及重新激活仍沿原协议和核心合同。开发计划原有 100/50/20ms 是人工推进用预算，真实 Windows Python 启动、恢复和解释器退出实测超出，分别调整开发默认 startup/hang/shutdown 为 5s/1s/1s；显式 Plan 仍严格执行，新增反例使用 300ms，package 原 manifest 外层预算未放宽。这不是生产 SafetyRTO 或延迟资格。

### 验证

平台：Windows 10 build 17763 原生 PowerShell；Python 3.9.18；Zig `0.17.0-dev.315+5b647b792`；沿用 512 MiB 集成测试栈。Debug 新 bounded-I/O 10 个故障场景通过，日志 `.scratch/build/source-audit-07-bounded-debug.log`。规范审查和规格审查最终各 0 项剩余发现，包含 `waitForExit` 补修复审。

初期 Debug 正例暴露了原人工时钟预算不适用于真实解释器，修正开发默认后正常输出集成通过；较大的恢复集成在 180s 测试外层预算到期时仍在推进，因此不记完整通过，后续以最终源码 ReleaseSafe 独立执行结果为准。早期 package 4 项中一项使用了重建完成前的旧 candidate 二进制，不能作为最终源码结果；最终重新构建后单独验收。

以下验收均使用冻结源码 `f9e85144847527b9459c47049874a746dd4c5480`。07 定向通过；模块全量失败，不能据此关闭地图：

```powershell
zig build test -Doptimize=ReleaseSafe --summary all
zig build install windows-chain -Doptimize=ReleaseSafe --summary all
# 下列四个正式入口依次执行（均 -OReleaseSafe --stack 536870912）
python tools/zig-entry.py run src/strategy/strategy_host_lifecycle.zig -OReleaseSafe --stack 536870912
python tools/zig-entry.py run src/testing/integration/strategy_host_integration.zig -OReleaseSafe --stack 536870912
python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -OReleaseSafe --stack 536870912
python tools/zig-entry.py run src/testing/integration/strategy_host_failure_integration.zig -OReleaseSafe --stack 536870912
python python/test_strategy_instance.py NativeAuthorityTransportTests.test_stalled_reader_cannot_hold_native_pipe_beyond_write_deadline WebInstanceTests.test_callback_hang_is_killed_by_external_budget WebInstanceTests.test_callback_timeout_does_not_hold_other_hosts_or_web_view WebInstanceTests.test_backend_pipe_eof_stops_and_reaps_python_host
python tools/zig-entry.py build-exe src/testing/integration/strategy_host_bounded_io.zig -target x86_64-linux-gnu -OReleaseSafe -fno-emit-bin --stack 536870912
```

最终结果（2026-11-05）：

| 验收 | 实际结果 | 日志（均位于 `.scratch/build/`） |
|---|---|---|
| 统一 ReleaseSafe | 退出 1；883/884 单元测试通过，新 bounded-I/O executable 通过（10 个故障场景） | `source-audit-final-releasesafe.log` |
| lifecycle 独立正例 | 退出 0；握手、四 Host、恶意能力、正常退出、崩溃/挂起重建与旧 session 拒绝 | `source-audit-07-strategy_host_lifecycle-releasesafe.log` |
| Host output 独立集成 | 退出 0；合法输出、共享权威链、重复/冲突拒绝、文件重开 | `source-audit-07-strategy_host_integration-releasesafe.log` |
| checkpoint/recovery 独立集成 | 退出 0；真实 checkpoint、恢复、迁移/重建、多个经济阶段与旧 session 拒绝 | `source-audit-07-strategy_host_recovery_integration-releasesafe.log` |
| failure 独立集成 | 退出 0；四 Host 故障隔离、正常 cursor 连续、重复 intents=0 | `source-audit-07-strategy_host_failure_integration-releasesafe.log` |
| Windows chain + 正式 executable 构建 | 退出 0，11/11 构建步骤；historical simulated chain/disk recovery、snapshot transfer、OKX offline 子合同通过；输出总资格 `windows_process_chain_verified=blocked`、`offline=blocked` 原样保留 | `source-audit-07-windows-chain-releasesafe.log` |
| 既有 package watchdog 定向 | 最终重建后 4/4 通过、0 skip、退出 0；阻塞写、callback 挂起、其他 Host/Web 进展及 backend EOF 回收 | `source-audit-07-package-releasesafe.log` |
| Linux x86_64 GNU 交叉编译 | ReleaseSafe、退出 0；非 Linux 原生运行证据 | `source-audit-07-linux-compile.log` |

全量唯一失败：`Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority`。独立过滤同一用例复现 `short_write case=11 point=root_publish skip=0` 的 `DecisionLogUnavailable`，退出 1（共享入口 1 passed、目标 1 failed），见 `source-audit-final-owner-interruption-repro.log`。Store、Owner 及该回归源码相对 07 前基线均无修改，独立进程亦可复现；此用例不调用 ManagedHost。按地图失败规则重新打开 [05](05-physical-recovery-suffix.md)，恢复资格及根因继续核实，不把 07 Host 定向通过扩写为全模块通过。本次未扩展修改 Store/Owner，也未再次执行全量。

新 bounded-I/O 验收 executable 已直接接入 `build.zig` 的 test step，因此统一全量会实际执行 10 个场景，而非只导入文件。其他独立 Host 正例入口在相同冻结源码补最小必要 ReleaseSafe 验收。

未读真实凭证、未访问 Demo/Testnet、未下订单。Windows chain 仅使用现场生成的 fixture credentials 和 SimulatedVenue；Linux 原生、目标硬件、真实平台耐久性、durable runRole 超时故障注入、容量/尾延迟及生产资格未验；不把离线撤权 seam 或交叉编译扩写为上述资格。
