# 05 恢复保留 manifest 未覆盖的物理尾部

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: resolved
Evidence level: 故障注入与文件重开已复现，F5

## Question

如何在 manifest 发布中断后保留真实物理高水位，让 Owner 正确隔离未提交尾？

## Problem Statement

segment 已写入 sequence=3，manifest 仍记录已提交 sequence=2。
重开仅呈现 manifest.byte_len 前缀，Owner 看不到需要隔离的真实尾部，可能复用已写序号。

## Solution

区分并验证已提交前缀与物理尾部；保留高水位和证据，未提交事实不入账，相关 Owner 不继续写入或发送。

## User Stories

1. 作为恢复执行者，我希望看见真实物理尾，以免将歧义记录视为不存在。
2. 作为账户所有者，我希望仅重放提交前缀，以免应用未提交经济候选。
3. 作为审计者，我希望已写序号不复用，以免新事实覆盖旧证据身份。
4. 作为运维人员，我希望损坏尾部失败关闭，以免系统猜测修复。
5. 作为恢复执行者，我希望 Owner 保持 closed，以免旧热态被误当重新授权。
6. 作为审计者，我希望启动不改磁盘证据，以便后续调查。
7. 作为维护者，我希望内存与文件 adapter 合同一致，以免 fixture 掩盖差异。
8. 作为账户所有者，我希望无尾正例保持正常准入，以免所有重启都永久不可用。

## Implementation Decisions

- Store 解释已提交内容与物理尾，Owner 执行 quarantine；文件布局不泄漏回核心。
- 完整 suffix 保留真实 last_sequence、摘要及可验证字节；截断、损坏或无法解释的内容失败关闭，不能静默丢弃。
- 仅提交前缀进入经济重放；Owner 恢复后保持 closed，不恢复发送能力。
- 恢复不截断、不改写 manifest、不删除孤尾、不复用序号。
- 优先保持现有 Store interface；若原表示确实不足，需明确所有消费者及格式影响，不能只改一个调用方。

## Testing Decisions

- 通过公共 Store append/commit/故障发布/文件重开，再进入实际 Owner 恢复入口。
- 复用 physical uncommitted suffix、manifest 故障矩阵及 Owner 恢复验收。
- 覆盖 segment 发布后/manifest 发布前、完整/截断/损坏尾、seal/rotate 周边和无尾正例。
- 检查物理高水位、提交 barrier、经济状态、Owner.closed 及启动前后文件摘要。
- 证明恢复及后续拒绝均不发送、不复用序号；平台证据单独记录。

## Acceptance Criteria

- [x] 原反例重开保留完整 sequence=3 的物理高水位和证据，不将其视为不存在。
- [x] committed_barrier 仍为 2，sequence=3 不进入权威经济重放。
- [x] 实际 Owner 观察尾部后 closed，后续追加与发送拒绝。
- [x] 截断、损坏、不可解释尾部失败关闭，不猜测截断恢复。
- [x] 恢复不改磁盘证据、不复用序号；无尾正例遵循既有恢复准入。
- [x] Store/Gateway/Owner 最小定向回归通过，Windows/Linux 范围明确；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行。

## Out of Scope

自动修复孤尾、推断已提交经济事实丢失、将 Windows 重开验收替代 Linux 断电资格。

## Further Notes

修复 ADR 0013 的既有合同；06 是独立耐久性核实任务，不是本票 blocker。见[审阅证据](../evidence.md)。
规格发布阶段未实施；2026-11-04 实施证据见下文。

## Answer

### 2026-11-05 重开修复

源码基线：`f9e85144847527b9459c47049874a746dd4c5480`；修复提交：`9f89c258bfb34e83f46633b861c1aa2d720a42ce`。本节覆盖下方历史“尚未精确归因”的状态；历史失败记录保留。

- **根因已确认**：seal 先同步发布包含 footer 的完整 segment，随后 root_publish 失败，manifest 仍认证 seal 前的前缀。重开正确保留 footer，且 `last_sequence == committed_barrier`，不存在未提交业务记录。Owner 显式继续 checkpoint 时跳过重复 seal，Store 原 rotate 却用旧 manifest 的 byte_len/digest 生成归档页；`archiveReceipt → verifyArchivePayload` 发现它与实际 sealed 文件不符，返回 `ArchiveRootConflict`，Owner 对外表现为 `DecisionLogUnavailable`。这不是 Host 故障，也不是本次证据证明的断电经济损失。
- **最小修复**：只在 `LinuxFileAdapter.rotateImpl` 构造归档页时，将临时 descriptor 的长度和摘要绑定到已验证的完整 sealed journal。复用现有 snapshot/barrier、记录范围、归档发布、同步和失败锁存检查，不增加 I/O 或新接口。恢复本身仍不写磁盘；有未提交记录的 suffix 仍由 Owner 隔离并拒绝追加、checkpoint 和发送。
- **格式影响**：Store interface、manifest/journal/snapshot schema、CanonicalStateDigest 均不变，不迁移或改写历史孤尾。先前失败续作若已经发布错误归档对象，本次不提供自动修复；既有校验继续失败关闭。
- **红灯证据**：原 Owner ReleaseSafe 过滤命令再次在 `short_write / root_publish / case=11 / skip=0` 失败，入口计数 1 passed、1 failed；日志 `source-audit-05-reopen-red.log`。扩展既有 Store 边界回归，在恢复后显式 publishSnapshot/rotate，再读取回执，修复前精确失败为 `ArchiveRootConflict`；日志 `source-audit-05-store-reopen-red.log`。
- **回归增强**：Store 检查回执的物理长度、摘要和完整认证验证；此前的重开/拒绝不改文件断言保留。Owner 既有 5×18 文件中断矩阵补充无未提交尾时不 closed、再次重开仍不 closed 且发送拒绝。经济状态、Unknown、费用、reservation、权威引用与 digest 继续按原断言验证。
- **复审**：按 code-review 技能从本轮固定基线独立执行两轴只读审查，Standards 硬性违规/启发式异味均 0，Spec 缺失/错误/越界均 0；审查本身未运行测试。

定向验证：Windows 原生，Zig `0.17.0-dev.315+5b647b792`、Python 3.9.18；Store Debug **6/6**、Owner ReleaseSafe **5/5** 均通过、退出 0。Owner 计数含共享入口、物理尾隔离、5×18 文件故障矩阵、显式 checkpoint 续作及导入的 Store 边界回归，不将导入重复算作独立新增覆盖。日志为 `source-audit-05-reopen-store-debug.log`、`source-audit-05-reopen-owner-releasesafe.log`，均位于 `.scratch/build/`。

```powershell
python tools/zig-entry.py test src/persistence/durable_store.zig -ODebug --stack 536870912 --test-filter 'physical crash suffix' --test-filter 'committed recovery prefix' --test-filter 'checkpoint store file fault boundaries' --test-filter 'checkpoint store virgin committed'
python tools/zig-entry.py test src/runtime/demo/demo_authority.zig -OReleaseSafe --stack 536870912 --test-filter 'Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority' --test-filter 'physical crash suffix' --test-filter 'Checkpoint owner explicitly resumes'
```

源码 SHA256：`durable_store.zig = 20942516AC85B87A9BD004FB2B2EC5FAA4245EA9325FF06BCE8A6D4C082719EB`；`demo_authority.zig = 46E87B50347C644003C6DF143AF97826CBE070C47A72734E49F10C1E1DA0FFB7`。身份文件：`source-audit-05-final-source-identity.txt`。

最终统一验收：上述冻结源码上执行 `zig build test -Doptimize=ReleaseSafe --summary all`，退出 **0**，**884/884** 单元测试通过、构建 **6/6**，独立 `strategy-host-bounded-io` executable 成功；日志 `source-audit-05-final-releasesafe.log`。四个未接入单元全量的正式 Host ReleaseSafe 独立验收也在相同源码通过、退出均为 0，命令及日志见地图 [Final ReleaseSafe evidence](../map.md#final-releasesafe-evidence)。本票 resolved，模块 Final ReleaseSafe=passed。

未读真实凭证、未连 Demo/Testnet、未下订单。未补跑 Windows process-chain/package watchdog、Linux 交叉编译或原生测试；此前 07 的这些结果只保留为其历史源码证据。本轮全量及四个独立 Host 入口不替代真实断电、目标 Linux 文件系统、durable Windows role 超时注入、容量/尾延迟或生产资格。

### 历史：最终验收重开记录

2026-11-05 最终验收重新打开：源码 `f9e85144847527b9459c47049874a746dd4c5480` 的统一 ReleaseSafe 为 883/884；既有 `Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority` 失败。独立命令再次复现 `short_write case=11 point=root_publish skip=0` 返回 `DecisionLogUnavailable`（退出 1）。该 case 为 checkpoint seal 周边 root 发布中断后的重开/恢复继续场景；尚未精确归因到 Store 或 Owner 的具体检查，不能宣布为数据丢失、manifest 同步或 Host 缺陷。05 的故障恢复验收重新作为 Frontier，06 的既有定向记录保留，若定位影响其合同再更新。模块 Final ReleaseSafe=failed，不能沿用下方历史 resolved 结论。

```powershell
python tools/zig-entry.py test src/runtime/demo/demo_authority.zig -OReleaseSafe --stack 536870912 --test-filter 'Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority'
```

日志：`.scratch/build/source-audit-final-releasesafe.log`、`.scratch/build/source-audit-final-owner-interruption-repro.log`。07 的改动没有触及该测试、Store 或 Owner 源码；其真实子进程及恢复集成定向证据见 [07](07-host-bounded-io.md#answer)。本轮完成 07 并记录本失败，不认领后续 05 修复；下文为 2026-11-04 的历史定向证据。

2026-11-04：已完成本票实现、Debug 定向验证和两轴审查，本票 resolved。模块最终 ReleaseSafe 待验。

### 实现与源码身份

- 基线：`4832623d1f3a797ceb42460ba2e6398cb2bd044a`；实现提交：`1d533b5ba7c8ca3a5cff3f78993def5a71e57f7b`。
- `src/persistence/durable_store.zig`：先独立验证 manifest 前缀的摘要、完整记录边界、first/last sequence、记录数及 committed barrier，再加载并校验完整物理 segment。完整 suffix 保留真实 last_sequence、原始字节及物理摘要；不提升提交 barrier。未完整消费的记录/尾部、footer 后字节、损坏或序号缺口失败关闭。尚无 snapshot 的 recovery_only 结果同样保留完整物理证据。
- 复用现有 `Owner.recoverInto`：只重放 committed prefix，看到未提交物理尾后保持 closed，拒绝 apply、checkpoint 与 send。Owner 生产逻辑没有改动，新增测试复用现有经济 fixture 和 CountingSimulator。
- Store interface、manifest/journal/snapshot schema、CanonicalStateDigest 格式均未改变；不写迁移层，不改写既有磁盘状态。segment_digest 按既有含义返回完整物理 segment 的摘要。
- 文件 SHA256：`src/persistence/durable_store.zig` = `5BE62E3A46F62F8C6547F293921E39C44307FBE7F71CC48ECDC64813F4569B24`；`src/runtime/demo/demo_authority.zig` = `8899DAFAD9AF1534260AC25C41CD99C5D1C38A47DBBD92E1695BD383807B4042`。

### 反例与正式回归

- 先修改既有 public Store suffix 回归，令 append sequence=3 在 segment 发布后、manifest root_publish 前注入 EIO；原实现稳定失败：`expected 3, found 2`。修复后 `last_sequence=3`、`committed_barrier=2`，tail 仅包含 2，active_segment 包含 3 且物理摘要相同；MemoryAdapter 对照保留同样的未提交尾语义。
- 新增文件边界回归覆盖 8 类：截断记录、尾部 CRC 损坏、footer 后杂字节、manifest 覆盖前缀损坏、合法 CRC 下的序号缺口、seal 发布中断、rotate 发布中断、无 snapshot 的完整 suffix。前五类 recovery_only/closed 并拒绝追加，后三类保留相应高水位、提交屏障和 seal 状态；重开及拒绝后 segment 和 manifest 摘要不变。
- 新增实际 Owner 文件重开回归，覆盖无尾与 root_publish 失败两支。故障候选是第二笔经济 Fill；只写入首个未提交记录即发布失败，恢复后唯一已应用成交量仍为 40，经济投影和 CanonicalStateDigest 等于已提交前缀。suffix Owner.closed，apply/checkpoint/send 均拒绝，CountingSimulator 发送数为 0；再次 recover 的物理高水位/摘要与目录全部文件摘要不变。无尾 Owner 不 closed，source 可读，仍保留既有 recovery_admission_pending，未重新授权发送。
- 新回归共置于 DurableStore/Owner；两者已在 `src/main.zig` 的 test 入口导入，不需新增独立验收程序或构建接线。

### 最小 Debug 定向验证

平台：Windows 原生 PowerShell；Zig `0.17.0-dev.315+5b647b792`；全部使用 Debug 和仓库既有的 512 MiB 测试栈。首次未指定测试栈产生 stack overflow，补 `--stack 536870912` 后才得到上述业务红灯；栈失败不计业务证据。

```powershell
python tools/zig-entry.py test src/persistence/durable_store.zig -ODebug --stack 536870912 --test-filter 'committed recovery prefix' --test-filter 'physical crash suffix' --test-filter 'checkpoint store file fault boundaries' --test-filter 'checkpoint store virgin committed'
python tools/zig-entry.py test src/runtime/demo/demo_authority.zig -ODebug --stack 536870912 --test-filter 'physical crash suffix'
python tools/zig-entry.py test src/execution/execution_gateway.zig -ODebug --stack 536870912 --test-filter 'Gateway recovers accepted and Unknown' --test-filter 'Gateway accepted outcome commit failure'
zig fmt src/persistence/durable_store.zig src/runtime/demo/demo_authority.zig
git diff --check
```

- Store **6/6**，退出码 0；包含共享入口、原反例、8 类新边界、已有 5×9 发布故障矩阵、virgin 正例和 committed prefix 部分帧检查。
- Owner **3/3**，退出码 0；包含共享入口、新 Owner 回归及其导入的 Store 边界回归。这些是测试入口计数，导入回归不另算新增独立覆盖。
- Gateway **3/3**，退出码 0；包含共享入口、accepted outcome 提交失败、accepted/Unknown 一起恢复而不发送。
- fmt/check 通过。Store/Gateway 日志分别为 `.scratch/build/source-audit-05-store-debug.log`、`.scratch/build/source-audit-05-gateway-debug.log`；Owner 终端结果与上述行为记录于本票。

### 审查与边界

- 规范审查：独立审查 `4832623d...1d533b5b`，硬性规范违规 0 项，值得提出的启发式异味 0 项。
- 规格审查：独立核对同一提交及 Store → Owner 当前调用链，缺失/错误要求与越界实现 0 项。审查未运行额外测试，未修改源码。
- 仅实施 05；06、07 尚未完成，不运行逐票全量。Final ReleaseSafe 保持 pending，所有修复及审查修正完成后按地图在最终源码统一执行一次全量。
- 未测 Linux 原生文件系统、断电/随机 kill、容量/延迟或生产资格；未访问凭证、Demo/Testnet 或真实订单。Windows 离线文件重开不证明目标 Linux 耐久性，06 的 manifest 耐久性仍为独立任务。
