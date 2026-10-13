# 05 优化后的审查记录

## 当前功能验收与两轴审查（2026-10-13）

当前源码身份为 [功能源码清单](05-functional-source-manifest.json) 的
`85c00368e0bce74b876a6934864911bb810094992434e29e95da7536d975f999`，
固定基线 `229330155abdff816dc90cae669c993a606f7863`，源码尚未提交。
用户最新要求以全部功能点正确为重点，不执行千单或容量压力测试；订单夹具
每类 live/retained terminal 总量不超过100。以 [map 的最新规则](map.md) 和
[容量合同的执行口径](capacity-contract.md) 为准，生产容量常量未变。

Standards 与 Spec 两轴对当前冻结源码的只读复核均未发现具体剩余 P1/P2。
共享 archive quota 的 journal 轮转和业务历史写入统一计入两类保留字节，
溢额回归验证失败关闭及历史保留。1GiB 是 MemoryAdapter 功能夹具实例配额，
不授予 RSS、物理索引、持续保留或平台资格；这些仍需后续票证明。

最新三处夹具调整保留功能断言：`order_public_capacity_acceptance.zig` 四 Owner
同时各25 live/25 terminal，先归档初始100终态，再十轮每 Owner结束、归档及
补入5单，最后重开 Owner/Gateway，检查 canonical digest、身份高水位、
dispatch/CID 和 SDK 零新增发送。`order_capacity_acceptance.zig` 保留四分片
十轮归档、八单 Unknown/PendingCancel pin 与身份不推进；三单明确注入已有
pressure latch，验证保护撤单和归档不能清除锁存，不冒充满载触发测试。
`core_observation_capacity_acceptance.zig` 保留500观察组合、四路由及100 selected
live；0/1/75/76部分成交和90撤权、保护撤单、重新准入分支仍实际执行，
恢复、来源隔离及注册表边界断言保留。CCC/多成员公共链与冷重复/冲突覆盖未删。

实际验证结果已从日志与 result JSON 核对：

- 完整 ReleaseSafe **538/538，退出0**：[结果](05-functional-full-releasesafe.result.json)、[日志](05-functional-full-releasesafe.log)。
- 随后完整 Debug **538/538，退出0**：[结果](05-functional-full-debug.result.json)、[日志](05-functional-full-debug.log)。ReleaseSafe 于14:37:07 UTC结束，Debug于14:37:09 UTC开始、15:20:23 UTC结束，两个完整测试串行执行。两份日志均包含四 Owner 初始驻留、初始归档、十轮补单及最终恢复用例通过。
- 同源码应用与 CLI ReleaseSafe 重建均退出0：[应用构建](05-functional-app-build.result.json)、[CLI构建](05-functional-cli-build.result.json)。
- 同一 CLI 的 `--offline-fixture` 与 `--windows-chain-test` 均退出0：[fixture结果](05-functional-cli-fixture.result.json)、[fixture日志](05-functional-cli-fixture.log)、[进程链结果](05-functional-cli-chain.result.json)、[进程链日志](05-functional-cli-chain.log)。进程链报告保留 `production_qualification=false`，不据离线成功授予生产或平台资格。

上述执行由 Root 完成；独立审查代理只读核对源码和结果，没有运行测试、构建
或干预进程。第05票、证据与地图的最终状态由 Root 同步后另行核对，06–12
不因此关闭。取消的压力验收不作为本轮功能缺口，也不把小规模结果写成容量资格。

## 历史审查与诊断记录（以下均非当前状态）

以下保留历次冻结身份和原文，供追溯优化、故障及覆盖补强。其“尚未运行”、
“仍在执行”、“保持 in-progress”和千单/压力要求均是当时状态；当前身份、
用户执行口径及完整结果仅以上方当前记录为准。旧失败或中断日志不能替代
当前验证，旧审查也不能单独证明当前通过。

历史源码身份：`05-optimization-source-manifest.json`，89 文件 SHA-256 聚合值 `dd86f518fa674ddffbae6edd8dc57a6398f46e7e7905fb9d2c8618d66435e307`。当时源码尚未提交，第 05 项保持 in-progress。

## Spec

GPT 6.1 Sol / medium 子代理只读核对当前 ticket05、容量合同、ADR 0013、OMS/Owner/Core/Gateway/Store 公共调用与验收。未确认新的 P1/P2 缺陷。

- OMS 归档需要安全终态、reservation/replacement/predecessor/组引用闭合、唯一 applied Fill 等于终态累计量，以及完整经济可见性和 30 秒迟到窗口。FoundTerminal 单独不能归档。
- Owner 先发布认证业务历史，再持久提交资格与根、释放 OMS，最后持久回收 Gateway；失败关闭，恢复隔离未提交 decision 尾部。
- 冷查验绑定首次输入、完整身份和 root/epoch/barrier，同订单先前候选阻挡后续状态；延期 admission 保留首次摘要。
- 未解决 Unknown 保持 pin，历史 resolved_unknown 不授予新的发送许可。
- 优化中的槽位读取检查完整 Order ID；dispatch bitmap 命中仍检查完整 command ID。

四 Owner 矩阵的准确范围为：每分片先同时保留 1,024 live + 3,600 terminal，随后十轮各替换 64 个订单，累计 4,240 terminal，再进行恢复核对。跨越 4,096 容量边界一次，不能表述为十轮各 4,096 个终态。

## 优化路径与别名修复

同模型子代理只读审查 owned-candidate 提交/错误发布/journal rollback、借用编码与旧 canonicalizer 对照、检查点 scratch、MemoryAdapter 双版本轮换。

审查发现 inline current 保存可能覆盖或释放借用的 previous 输入。修复仅在这一危险别名路径、任何缓存和 manifest 修改之前复制输入。复查未发现剩余具体阻碍：临时复制失败保留两个版本，后续分配失败保留当前版本作为 fallback。

## 仍需完成

审查不替代测试。优化回归 ReleaseSafe 7/7 已通过，四 Owner 真容量矩阵 PID 9404 尚在运行；完整当前源码 Debug/ReleaseSafe、构建和最终审查封存仍需完成。资源、保留、Windows/Linux 平台和 Venue 在线资格分别由后续票证明。

## 第二轮复查：Standards

第一轮矩阵在 1,024 终态后停止，第二轮身份取代以上初始身份：`05-optimization-second-source-manifest.json`（`be15d0da3e1f4a827304192b97e91d7f39a0fe6675ae3802141b04333db72665`）。

Standards 轴确认一项 P2：Core A 归档已提交而 Gateway A 尚未记录时，恢复后直接归档 B 会令 Gateway 因前驱根不匹配拒绝 B，且 Core 最后回执变为 B，无法继续 A。

修复复查通过：Owner 在 B 的 builder、Store 和 Core 发布之前调用 Gateway 完成前一归档；同根检查持久尾部，sealed checkpoint 先补完，失败关闭 Owner。新增两订单回归覆盖原始 Gateway append 前边界及补交失败。未确认剩余 P1/P2，也没有额外可行动的代码气味问题。分布修改遵循现有所有权，借用编码和未发布候选服务本票容量范围；这些是审查判断。

## 第二轮复查：Spec

Spec 轴复查确认归档前驱修复符合 ADR 0013 的可恢复提交责任。失败保留旧根、屏障、A 回执与 B 热单；成功根连续、发送数不增加、最终恢复摘要一致。

owned Core/Venue 成功复用外层私有候选，普通失败回滚 previous，经济故障恢复后锁存；资产拒绝、终态冲突和 projection invalidation 的权威分支保留，Owner 仍在 Store commit 后发布。未确认剩余 P1/P2或未授权功能。完整当前源码与真实四 Owner 容量仍缺最终通过证据，第 05 项不能关闭。

两个审查轴均为 GPT 6.1 Sol / medium、只读，不执行测试或构建。Root 的第二轮优化回归 8/8、前驱恢复回归 2/2 已通过；完整 Debug/ReleaseSafe 当前源码正在编译。旧 PID 9404 已结束，不能沿用“仍在运行”的初始记录。

## 调用端最终复查：Standards

当前源码身份为 `05-caller-heap-source-manifest.json` 的 `6b6864ee33bfbd764128bd79bd48578efe32a104d9df51467990147c9d98e814`，基线 `229330155abdff816dc90cae669c993a606f7863`。GPT 6.1 Sol / medium 只读复查未确认剩余具体 P1/P2。

复查包括前驱归档的提交顺序、owned candidate 的普通回滚与权威失败发布、快照缓冲及恢复 Store 的生命周期、bootstrapInto 初始化/失败关闭、SimulatedVenue 时间在生成 envelope 时复制、按 shard origin 恢复 accepted ClientOrderId 且不新增发送，以及五个 fixture 独立堆槽位与指针验证。未发现额外可行动的代码气味问题。

纯离线 Windows 进程链已经退出 0；完整 Debug/ReleaseSafe 测试程序编译退出 0。ReleaseSafe 完整用例正在运行，应用构建正在运行，完整 Debug 尚未运行。此审查不能代替完整容量、故障、资源或平台资格证据。

## 调用端最终复查：Spec

同模型/强度只读复查当前冻结身份未确认新的 P1/P2。bootstrapInto 保留 stream/domain/gate 校验与失败关闭；模拟权限和回执时钟来自当前 Owner；Windows 重放经 Store/Owner 校验已提交前缀、完整摘要和无发送能力；accepted 身份按来源域读取并拒绝与 uncertain 身份冲突。fixture 堆初始化保留五个独立轨迹、经济/屏障/坏输入与 golden 验证。

审查未重算源码身份或运行构建/测试；完整当前源码两种优化模式和四 Owner 真容量矩阵仍需最终结果。最新调用端修改不替代资源、持续保留、平台或 Venue 资格。

## 第三轮 OMS undo：Standards

当前身份取代前轮为 `05-oms-undo-source-manifest.json` 的 `3b5802307eb4e41230d344364567de2d8b20477b7eef143d08d6095094639d75`。GPT 6.1 Sol / medium 只读复查五个事务体及 helper，未确认剩余具体 P1/P2。

既有行修改被覆盖：group 的目标与数值取消组；dispatch 的目标与其取消组；report/reconciliation 的单目标；replacement 前驱。createOrder/emit 只追加并推进计数及身份；失败恢复所有原计数和高水位。超过 40 行在任何修改前进入原完整事务，保留跨策略数值 group 行为；没有新增容量错误。各包装器错误标志与原行为一致：group 保留 recovery/capacity，report/reconciliation 保留 recovery，dispatch/replacement 恢复两者。未使用尾部在计数之外，不进入现行摘要/快照；undo 不属于 Oms，没有持久化字段或格式修改。

没有额外可行动的代码气味。审查未执行测试/构建或测量帧/性能；常见路径仍有 40 行局部存储和预选扫描，大取消组保留完整复制成本。当前完整套件/Owner 容量结果仍待完成，资源资格未取得。

## 第三轮 OMS undo：Spec

### 第四轮 builder 双游标：独立 Spec 复查

### 第05项最终覆盖补强

独立 Spec 代理只读验收审查明确 CCC 与多成员此前主要为直接 OMS/Core/Store
操作，不能证明 Owner decision commit/Gateway 回收恢复。Standards 代理新增
真实 CCC 初版公共链，Root 接手补齐两成员及归档 dispatch 的完整冷重试。
Root 复核两条均通过 Owner.apply/send/applyAdapterBatch/archiveTerminalOrder，
按真实资格顺序导出证据；恢复同 canonical digest 后，四条 typed dispatch
各两次 accepted 不发送，再验证原组重复/冲突。组/前驱 pin、单调身份、
四次真实发送与恢复计数均有断言。Cycle.submit/runMatrix 未改；terminal
只提取 coverage helper，仍在原位置调用同一次 maintain。

最终两模式定向各2/2及既有四条 Debug4/4通过；独立最终复查因子代理额度
限制尚未完成，不把 Root 自查冒称双轴独立结论。完整两模式及矩阵仍待结果。

额度恢复后 Standards 独立只读复查最终源码未确认具体 P1/P2：四条发送证据的
typed 查验/每条两次 accepted 冷重试发生在冲突前，SDK 计数不变；CCC 真正
走非原生 amend/cancel confirmed/successor place/cancel，证据按资格顺序导出。
两成员逐次 send/drain 并提前复制命令，Order/Command/CID 分别独立，共享意图
到最终成员才释放。对象/Store/guard 生命周期正确，原矩阵维护频率不变。
该审查未执行测试或构建，不能替代当前完整验证；Spec 最终独立结论仍待收取。

最终 Spec 独立只读结论已收取：在冻结身份 `3c1d7b91` 上，先前 CCC/多成员
公共链的两处覆盖缺口由真实断言补齐，未发现 P1/P2。两例 Owner/send/adapter
完成四次真实发送、引用 pin、按资格归档、canonical digest 恢复及四条证据各
两次正常 accepted 冷重试，SDK 不增；之后组重复/冲突保留经济及身份计数。
冲突前已经验证正常重试，不依赖失权后的 NotSent。原矩阵负载/维护频率未变。
两轴均未运行测试/构建；不能据此把完整两模式或四 Owner 容量提前判为通过。

## 冻结身份的完整 WIP 收尾：Spec

GPT 6.1 Sol / medium 从固定基线229330155abdff816dc90cae669c993a606f7863
复核最终3c1d7b91全差异及新增模块，未确认剩余具体P1/P2。当前issue、合同、
CONTEXT、ADR0013中的安全终态/经济齐全/引用/迟到窗口、typed证明的来源/内容/
根/epoch/barrier/覆盖绑定、原候选时钟和有界延期满额关闭均保持；Owner历史→
Core→Gateway提交和前驱补交、孤尾隔离/身份不复用、Gateway namespace及
accepted/Unknown无重发、各格式codec/restore及活动前缀/Into发布闭合。
CCC/多成员真实公共链补齐，原千单负载及检查点频率未改。该轴只读，无测试/
构建/重新聚合哈希或进程干预。完整两模式/三阶段容量仍待真实最终结果，
每分片3600+10×64=4240，不代表十轮各4096；资源/保留/平台/Venue资格未取得。

## 冻结身份的完整 WIP 收尾：Standards

同基线/冻结身份，GPT 6.1 Sol / medium重新读取仓库规则、CONTEXT和相关ADR，
复核tracked diff、九个新增业务/验收模块及调用路径，未发现具体剩余P1/P2
或可行动smell。I/O外围所有权、完整proof绑定及失败关闭、归档提交/前驱恢复
顺序、OMS undo及大范围旧事务、Core rollback/权威失败发布、schema/codec/
活动前缀长度校验、完整accepted/Unknown恢复无发送、heap/Into生命周期与
失败目标发布均保持。新回归没有减少矩阵负载或维护频率。
该轴未编辑、测试或干预进程；完整矩阵未终态，不能提前关闭05或授予资源/
平台/生产资格。完整WIP两轴收尾现均已完成，测试仍待真实退出结果。

2026-10-13，GPT 6.1 Sol / medium 只读复查未发现具体 P1/P2。
OMS `commitOrderArchive` 通过稳定左移删除 intent，不排序或改写保留项；
释放后的表因此是原表有序子序列。双游标同时比较 strategy_instance 与
intent_sequence，跨策略同 sequence 不会误判。被删除项仍按原顺序编码，
GroupRecord 的构造、排序、去重及 SharedOrderHistoryGroup 拒绝检查保持。
新公开回归涵盖前/中/后存活意图、跨策略同 sequence 与 place/cancel；
需要以实际执行结果确认，审查自身未运行测试或测量性能。

同身份、同模型/强度只读复查未确认剩余 P1/P2。undo 恢复全部既有行、标量、活动前缀与单调身份，超过 40 行在修改前回退原完整事务，跨策略数值组取消语义保留。report/reconciliation 在回滚失败历史追加及订单修改后保留原 recovery_only；replacement 失败保留此前成功报告、前驱终态和 replacement。TradingShard/Owner 仍在未发布 Core 候选内执行 OMS，Store commit 后发布；ADR0013 归档顺序、Unknown pin 和重复不重发保持。

新增回归实际检查迟到失败及两类组范围的 rollback/fallback；未见验收被削弱。审查未运行测试/构建、未重算聚合身份。纯 OMS 容量通过不替代四 Owner 公共矩阵，完整 Debug/ReleaseSafe 和资源/平台资格仍待结果。
