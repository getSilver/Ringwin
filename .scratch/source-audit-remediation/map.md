# 核心与 Venue 合同审阅修复

Status: closed
Final ReleaseSafe: passed

## Destination

逐项修复 2026-11-04 当前源码审阅发现的五类可复现缺陷，并核实两个独立的静态风险。
沿用 TradingShard、VenueAdapter、ExecutionGateway、Owner、DurableStore 与 ManagedHost 的现有 seam，
不另建交易核心、通用协议框架或控制面。

基线：`d973030794cc78c0abc5ccd939dcc0ecabf30e98`。
原始发现、反例、既有测试结果及来源定位见 [审阅证据](evidence.md)。
本图发布表示规格可执行，不表示代码已修复、既有资格扩大或真实交易获授权。

## Definition of done

- 01–05 的原反例已通过对应公开业务 seam 转为正式回归，修复后预期安全行为成立。
- 06、07 完成真实调用路径与故障条件核实；确认的缺陷修复并验证，排除的风险记录充分反证。
- 成交修复保持经济原子性、唯一应用量、重复/冲突判断及恢复一致性；发送修复保留撤单与 Unknown 语义。
- 恢复修复保持已提交前缀、物理高水位与未提交尾隔离；不截断孤尾或复用序号来恢复可用性。
- 每票记录实际源码身份、命令、平台、优化模式、定向验证结果和未测项；全部修复完成后，在最终源码上统一通过一次 ReleaseSafe 全量验收。
- 若更改规范输入含义、持久状态、codec 或 digest，明确格式身份影响并执行相关恢复验证；不猜测兼容旧格式。
- 各票达到自身行为验收并填写定向证据后可设 resolved；这不表示最终全量验收完成。全部票完成且本图 Final ReleaseSafe 为 passed 后，本图才可 closed。
- 生产接线与容量资格仍由下文关联地图负责，不是本图完成条件，也不因本图关闭而获得资格。

## Rules

- 仅维护本地 Markdown，不同步 GitHub。使用 `ready-for-agent` 分诊；一次只认领并完成当前 Frontier。
- 认领前按当前源码重新检查问题和调用者，不能用本次审阅或历史 closed 状态替代核对。
- 2026-11-04 用户已确认测试 seam：TradingShard.apply；VenueAdapter → TradingShard；Gateway/VenueAdapter 与注入时钟、签名器、transport；Store → Owner 重开；ManagedHost 真实子进程。
- 01–05 是已复现缺陷；06、07 是核实及条件修复任务，不能写成已观察到的断电损失或全路径 Host 挂起。
- 未拒绝前不允许产生目标副作用；拒绝后允许按已有合同记录安全故障，不能要求整个 digest 不变而阻止必要锁存。
- OMS cumulative quantity 保持交易所报告状态；AppliedOrderFillQuantity 保持唯一已应用量，两者不合并。
- 不读取真实凭证、不访问 Demo/Testnet、不下真实订单。离线测试不能替代目标平台耐久性或生产资格。
- 测试先证明外部行为，复用已有 fixture/共享合同；临时探针转为正式回归时按仓库职责目录放置。
- 不按文件大小拆模块；不删除授权、持久屏障、Unknown、历史查证或回滚机制来减少代码。
- 保留用户其他工作区改动；本次规格发布不认领实现，不自动提交代码。

## Testing schedule

1. **逐票最小定向验证**：复现对应反例，修复后运行新增回归、必要正例及直接受影响的公共调用链。默认用 Debug；只有优化模式差异、平台行为或已有失败证据需要时，才补该范围的 ReleaseSafe 定向验证。每票不跑全量，也不默认把所有定向用例在两种模式各重复一遍。
2. **保留实质验收**：这项安排只合并全量运行，不删除各票要求的经济断言、故障重开、真实受控 Host 集成、快照/重放及失败关闭检查。测试稳定通过后不无理由扩大或重复范围。
3. **统一最终验收**：所有修复、必要审查修正与测试接线完成，冻结最终源码身份后，默认运行一次 `zig build test -Doptimize=ReleaseSafe --summary all`。不要求额外 Debug 全量波次。
4. **覆盖检查**：确认新增正式回归确实进入全量入口；必须独立执行的验收入口，在相同最终源码上补最小必要 ReleaseSafe 验收，不能将未被全量入口运行的程序算作通过。该补验不是再跑一轮全量。
5. **失败与后续变更**：全量失败时保持本图 open，定位问题并重新打开受影响票，先做定向修复验证，再重跑最终全量。验收后实现、构建或测试源码改变时，旧结果不能作为新源码的最终证据；纯文档更新无需重跑。默认一次不意味着失败后也禁止重跑。
6. **证据与关闭**：每票 Answer 区分“本票定向通过”与“模块最终 ReleaseSafe 待验”。最终结果统一记录本图的源码身份、命令、退出码、测试计数、日志及未测范围，再将 Final ReleaseSafe 更新为 passed。平台耐久性及生产资格未测项继续保留。

## Final ReleaseSafe evidence

### 2026-11-05 重开修复后的最终验收

- 冻结源码：`9f89c258bfb34e83f46633b861c1aa2d720a42ce`；Windows 原生，Zig `0.17.0-dev.315+5b647b792`、Python 3.9.18。身份及文件摘要：`.scratch/build/source-audit-05-final-source-identity.txt`；源码相对该提交无后续改动。
- 命令：`zig build test -Doptimize=ReleaseSafe --summary all`；退出码 **0**，**884/884** 单元测试通过，构建步骤 **6/6**；正式 `strategy-host-bounded-io` executable 输出 `strategy_host_bounded_io=passed`。日志：`.scratch/build/source-audit-05-final-releasesafe.log`。
- 05 重开定向：Store Debug **6/6**、Owner ReleaseSafe **5/5**，退出均为 0；原失败点及全部 5×18 文件中断场景通过。规范/规格两轴复审均 0 项；详见 [05 Answer](issues/05-physical-recovery-suffix.md#answer)。
- 全量之外的四个正式 Host ReleaseSafe 验收在相同冻结源码上成功，退出码均为 **0**，命令和日志见下表。恢复集成含真实 checkpoint、文件重开与共享 Owner 经济恢复路径；旧 session 和发送权保持隔离。

| 独立入口（均以 `python tools/zig-entry.py run <入口> -OReleaseSafe --stack 536870912` 执行） | 日志（`.scratch/build/`） |
|---|---|
| `src/strategy/strategy_host_lifecycle.zig` | `source-audit-05-final-host-lifecycle.log` |
| `src/testing/integration/strategy_host_integration.zig` | `source-audit-05-final-host-integration.log` |
| `src/testing/integration/strategy_host_recovery_integration.zig` | `source-audit-05-final-host-recovery.log` |
| `src/testing/integration/strategy_host_failure_integration.zig` | `source-audit-05-final-host-failure.log` |

- 未读真实凭证、未连 Demo/Testnet、未下订单。未补跑 Windows process-chain/package watchdog、Linux 交叉编译或原生测试；07 对应结果继续仅作为历史源码证据。Linux 原生、真实断电、durable Windows role 超时故障注入、容量/尾延迟及生产资格仍未验，既有 offline blocked 输出不提升。
- 七票均 resolved，最终源码全量及必要独立 Host 验收通过，本图 closed；上述未测资格继续由关联地图承接。

### 历史：重开前失败验收

- 冻结源码：`f9e85144847527b9459c47049874a746dd4c5480`；Windows 10 build 17763，Zig `0.17.0-dev.315+5b647b792`，Python 3.9.18。
- 命令：`zig build test -Doptimize=ReleaseSafe --summary all`；退出码 **1**；**883/884** 单元测试通过，新增有界 I/O 集成 executable 通过；构建步骤 4/6，失败导致 test step transitive failure。
- 唯一失败：`runtime.demo.demo_authority.test.Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority`；独立过滤同用例也失败为 `DecisionLogUnavailable`，05 重新打开。
- 日志：`.scratch/build/source-audit-final-releasesafe.log`、`.scratch/build/source-audit-final-owner-interruption-repro.log`；文件身份：`.scratch/build/source-audit-07-source-identity.txt`。
- 全量之外的必要 Host ReleaseSafe 验收全部成功，完整明细见 [07](issues/07-host-bounded-io.md#answer)。本结果不关闭模块；后续 05 修复及审查完成后须冻结新源码并重新执行最终全量。
- 未读真实凭证、未连 Demo/Testnet、未下订单；Linux 原生、真实断电、durable Windows role 超时故障注入、容量/尾延迟及生产资格未验，既有 offline blocked 输出保留。

## Route

| 票 | 类型与交付 | 状态 | 必须前置 |
|---|---|---|---|
| [01 Fill 与 Order 方向一致](issues/01-fill-order-side.md) | 修复：错误方向拒绝且经济投影不变，合法方向正常入账 | resolved | 无 |
| [02 Amend 授权与限额](issues/02-amend-admission.md) | 修复：Binance/Bybit 非撤单授权与改单暴露校验 | resolved | 无 |
| [03 最终发送期限](issues/03-final-dispatch-deadline.md) | 修复：签名等耗时工作后、实际发送前复核 DispatchDeadline | resolved | 无 |
| [04 Hyperliquid 返佣成交](issues/04-hyperliquid-rebate-fill.md) | 修复：明确零手续费与正返佣贯通核心、归档及恢复 | resolved | 无 |
| [05 物理 crash suffix](issues/05-physical-recovery-suffix.md) | 修复：物理尾保留并隔离；重开后补齐 recovered seal 的归档元数据，Owner 恢复与最终全量通过 | resolved | 无 |
| [06 Manifest 耐久性](issues/06-manifest-durability.md) | 核实并按证据修复：advisory 更新不能破坏先前提交的恢复索引 | resolved | 无 |
| [07 Host 有界 I/O](issues/07-host-bounded-io.md) | 核实并按证据修复：阻塞等待不绕过生命周期时限及撤权 | resolved | 无 |

依赖图：七张票均无必须前置，不为相邻源码人为添加 blocker。
建议执行顺序：01、04、02、03、05、06、07。02/03 与 05/06 分别触及相同实现，按序执行以便保留并复用前票回归。
这只是调度建议，不是证明其他票完成的依据。每票结束后重新核对依赖并更新下一 Frontier。

## Frontier

- 无。01–07 均 resolved；冻结最终源码的 ReleaseSafe 全量与必要独立 Host 验收通过，本图 closed。生产资格及其他地图的未完成项不因此关闭。

## Decisions so far

- 2026-11-05：按用户要求实施重开的 05，提交 `9f89c258bfb34e83f46633b861c1aa2d720a42ce`。确认 seal 的完整物理 footer 已发布、manifest 仍认证旧前缀；重开后的显式 checkpoint 续作用旧 manifest 长度/摘要生成归档页，导致 `ArchiveRootConflict` 被 Owner 转为 `DecisionLogUnavailable`。现仅在 Store rotate 时绑定真实 sealed segment 长度/摘要，不改恢复写入、提交屏障、suffix 隔离或格式。最小 Store 反例先红后绿，Debug Store 6/6、ReleaseSafe Owner 5/5（含全部 90 个文件中断场景）通过，规范/规格复审均 0 项。冻结该源码后最终 ReleaseSafe **884/884、6/6、退出 0**，有界 Host I/O executable 及四个正式 Host 独立 ReleaseSafe 验收通过；05 resolved，Frontier 清空，Final ReleaseSafe=passed，本图 closed。未重跑 process-chain/package watchdog/Linux，历史结果仍绑定旧源码；未做真实断电、目标机或生产资格。详见 [05 Answer](issues/05-physical-recovery-suffix.md#answer) 与本图最终证据。
- 2026-11-05：完成 07，源码提交 `c2c0ad62` 与退出等待补修 `f9e85144847527b9459c47049874a746dd4c5480`。真实 Host 10 个超时故障场景、四个正式 Host ReleaseSafe 独立验收及 package watchdog 4/4 通过，规范/规格两轴最终复审各 0 项；Windows offline 子合同命令成功但其全链资格输出仍 blocked，Linux 仅交叉编译。统一最终 ReleaseSafe 退出 1：883/884，唯一失败为既有 Owner checkpoint 文件中断恢复测试。独立过滤再次在 `short_write / root_publish / case=11 / skip=0` 得到 `DecisionLogUnavailable`；相关 Store/Owner/测试源码未被 07 修改，根因尚未精确归属。按失败规则重开 05，Frontier 回到 05，地图保持 open、Final ReleaseSafe=failed。未修改 Store/Owner 来扩展本次 07 实施；没有在未修复条件下重复全量。具体矩阵、命令、日志和未测项见 [07 Answer](issues/07-host-bounded-io.md#answer) 与 [05 Answer](issues/05-physical-recovery-suffix.md#answer)。
- 2026-11-04：按用户授权完成 06，源码提交 `a9c9a77fe680c2be0c9b96d0204ce0b7fe01ff49` 与最终补修 `3781870cd08153fb0c7b50a2347133d26ce158ec`。确认普通 append 替换全局 manifest 时跳过同步的静态风险；现统一同步临时 manifest、rename 及目录，不提升未提交 barrier。Windows 目录同步改用同一目录的独立写句柄并传播打开/flush 错误。两个反例先失败后通过：同步阶段被绕过、真实 Windows 共享冲突被隐藏。最小 Debug Store 6/6、Owner 3/3（含共享入口和导入回归）通过；规范审查 0 项，规格初审 1 项已修复、最终复审 0 项剩余发现。06 resolved，Frontier 移到无 blocker 的 07。本轮仅实施 06，不运行全量，Final ReleaseSafe 仍 pending。未做真实断电、Linux 原生或容量/延迟测量，不推断经济损失已发生或取得平台资格；发布顺序、平台矩阵、文件身份和命令见 [06 Answer](issues/06-manifest-durability.md#answer)。本地 tracker 保留未跟踪状态，源码提交不包含其余规格文档。
- 2026-11-04：按用户授权完成 05，源码提交 `1d533b5ba7c8ca3a5cff3f78993def5a71e57f7b`。文件 Store 独立验证 manifest 前缀后加载完整物理尾，保留高水位、原字节和物理摘要；截断/损坏/不可解释尾失败关闭。既有 Owner 只恢复已提交经济状态并隔离 suffix，拒绝追加、checkpoint 与发送。原反例先失败后通过；最小 Debug 定向 Store 6/6、Owner 3/3、Gateway 3/3（均含共享入口；Owner 还含导入的 Store 边界测试）通过，规范审查 0 项违规/异味、规格审查 0 项发现。05 resolved，Frontier 移到无 blocker 的 06。本轮仅实施 05，不运行全量；06、07 未完成，Final ReleaseSafe 仍 pending。故障矩阵、文件摘要、命令和 Windows/Linux 范围见 [05 Answer](issues/05-physical-recovery-suffix.md#answer)。本地 tracker 保留未跟踪状态，源码提交不包含其余规格文档。

- 2026-11-04：按用户授权完成 03，源码提交 `4832623d1f3a797ceb42460ba2e6398cb2bd044a`。Binance/Bybit 在签名成功后、消费改单引用和调用 transport 前以新单调时钟复核到期，拒绝为 not_sent/deadline_expired。两家慢签名反例先失败后通过；最小 Debug 定向 Binance 6/6、Bybit 6/6、Gateway 3/3、Hyperliquid 4/4（均含共享入口测试）通过，规范审查 0 项违规/异味、规格审查 0 项发现。03 resolved，Frontier 移到无 blocker 的 05。本轮仅实施 03，不运行全量；05–07 尚未完成，Final ReleaseSafe 仍 pending。操作系统抢占及 transport 内部排队窗口、检查点与完整命令见 [03 Answer](issues/03-final-dispatch-deadline.md#answer)。本地 tracker 保留未跟踪状态，源码提交未包含其余规格文档。

- 2026-11-04：按用户授权完成 02，源码提交 `93c7a9ec2e2daae037ca9261223963ed887bf3d0`。两家非撤单共用显式授权及单笔/批次限额，报告绑定 revision 与累计屏障并转换 TargetRemainingQuantity；无法证明时失败关闭。最小 Debug 定向 Binance 9/9、Bybit 8/8、Gateway 3/3（含共享入口）通过，规范审查 0 项违规、规格审查 0 项阻塞。02 resolved，Frontier 移到无 blocker 的 03。本轮仅实施 02，不运行全量；Final ReleaseSafe 仍 pending。现有 Gateway 原生改单仍缺少引用/屏障，后续 revision 与部分成交保守总量限额的能力边界见 [02 Answer](issues/02-amend-admission.md#answer)。本地 tracker 保留未跟踪状态，源码提交未包含其余规格文档。

- 2026-11-04：按用户授权完成 04，源码提交 `d9e6bef8e33443ea91fade6978a1ff890d91c6c1`。负费用输出同资产零 fee 和正 rebate，私有 ResumeCheckpoint schema 升为 2 并拒绝旧种子。最小 Debug 定向 5/5 + 2/2 通过（含两个共享入口测试），覆盖原文 adapter、在线 Owner、USDC、双顺序、RawIngress/快照尾恢复、归档重复和冲突；两轴审查均 0 项。04 resolved，Frontier 移到无 blocker 的 02。本轮仅实施 04，未运行全量，Final ReleaseSafe 仍 pending；详见 [04 Answer](issues/04-hyperliquid-rebate-fill.md#answer)。本地 tracker 保留未跟踪状态，源码提交不包含其余规格文档。

- 2026-11-04：用户授权完成 01 实施。源码提交 `9306d06e69a5d35773784e6e066bb44a531a1a1f`；在线成交准入与快照恢复补方向一致性检查，Debug 最小定向 6/6 通过（含共享入口测试），规范/规格两轴审查均 0 项发现。01 resolved，Frontier 移到无 blocker 的 04；本次只实施 01，未运行全量。最终 ReleaseSafe 仍 pending，详见 [01 Answer](issues/01-fill-order-side.md#answer)。本地 tracker 保留原有未跟踪状态，源码提交不包含其余规格文档。
- 2026-11-04：用户要求将审阅发现落实为文档，并确认沿用现有验收入口。发布五张修复规格、两张风险核实规格及可追溯证据。
- 2026-11-04：用户再次明确本轮只落实文档，不修改代码或做优化；ready-for-agent 仅为分诊状态，不是本轮开始实现的指令。
- 2026-11-04：按用户提出的安排，将 ReleaseSafe 全量测试集中到全部修复完成后的最终源码；逐票保留最小定向验证，不逐票重复全量。具体执行与关闭规则见 Testing schedule。本轮仅修改文档，未执行测试。
- 原始审阅的五类缺陷由七个反例场景支持；三项相关既有测试通过，不能替代新增反例验收。
- 保留 ADR 0001 的执行/行情分离、ADR 0004 的 Store seam、ADR 0007 的匿名 pipe、ADR 0013 的物理尾隔离及 ADR 0014 的独立成交累计。
- 正式规格不预先决定新 interface 或 schema 版本号；实施时据实际语义变更判断，不为局部修复建立兼容层。

## Not yet specified

### 已有生产任务的承接

Linux role 当前只完成进程控制骨架，实际交易状态、业务 drain 与运行接线须继续在
[生产地图](../production-readiness/map.md) 中收口，优先核对
[生产进程链](../production-readiness/issues/02-run-linux-production-process-chain.md) 与
[权威状态恢复](../production-readiness/issues/03-persist-and-recover-authoritative-state.md)。
后续应按当前源码更新业务接线矩阵、实际消费者、失败撤权及验收证据，不能凭 role ready/布尔 gate 判定业务闭环。
本图不复制上述实施票，不改旧票状态；真实 Venue、目标机、Web 发布与生产资格继续遵循原地图依赖及授权。

### 优化候选

- 状态复制：先测真实调用路径的复制字节量、栈峰值及尾延迟，核对已存在的 owned-candidate 路径，再决定是否优化。没有本次负载测量，不承诺性能收益。
- Owner 归属：Hyperliquid 复用的 Owner 位于 demo 命名目录；有后续功能修改时再核对是否应归入公共 runtime。不得复制 Owner 或混同 demo 授权。
- 入口组织：正式入口保持薄分发，验收实现按现有 testing/runtime 职责组织；不因本次审阅发起全树移动。
- 既有容量地图仅完成小规模功能闭合；参考 [容量地图](../core-continuous-capacity/map.md)，本图不重开压力测试或变更其未测范围。

这些候选不分配 ready-for-agent 实施票；先有测量或具体维护痛点，再写独立规格。

## Out of scope

- 新策略、交易所协议扩展、通用 transport/auth 框架、第二个控制面或核心。
- 历史生产经济状态自动修复、倒退、迁移或按新规则重算已有账务。
- 在线订单、真实凭证、Linux 断电/Canary、完整性能和生产资格波次。
- 将历史模块的 closed/resolved 改写为本次缺陷已修复，或凭局部测试宣称全项目无漏洞。
