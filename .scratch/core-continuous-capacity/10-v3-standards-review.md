# Frontier10 v3 Standards 增量独立终审

沿用AGENTS、CONTEXT、相关ADR、Zig规范与完整十二项smell baseline；保留v2报告。本轮只读复核c29冻结包至v3的新增fixture差异及最终身份，不改源码/六producer、不编译或跑全套。

**未发现确认P1/P2。**

硬规则：逐文件对照`10-owner-stack-second-fix-frozen.zip`，源码差异仅`src/windows_capacity_shared.zig`与`src/main.zig`。Core、Store、Owner事务/rollback及schema均未再次修改。

`windows_capacity_shared.zig:54,65` 在发布前记录Owner sequence，只有公共apply实际提交新summary后才checkpoint。无变化时保留原快照，避免封存空tail；不是吞掉checkpoint错误。apply失败仍立即传播，发生新提交时checkpoint失败仍传播。`account_coordinator.zig:2870,3055` 的权威提交及关闭行为未变；recovery_only和既有lease校验仍执行。

`windows_capacity_shared.zig:83` 新回归先持久提交changed summary，再调用unchanged更新并比较完整Report，重开后再次比较；之后再次changed提交、校验barrier推进并重开比较。覆盖跳过空checkpoint后仍可继续真实提交，而非只测不抛错。使用独立临时目录，只成功后删除，失败路径已打印且保留。四个summary没有创建新订单，未扩大live/terminal资源范围。`main.zig:42,263` 显式导入及测试引用保证该用例从main测试根可发现。

判断性结论：十二项smell未出现需阻断问题；此处用既有持久sequence判定提交，比增加fixture自有dirty状态更直接。未声称测量线程栈峰值。

只读实算114文件与`10-final-v3-source-manifest.json`逐项相等，亦与identity相等：SHA256 `f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42`。六producer实际SHA均与`10-final-v3-identity.json`一致：

| producer | SHA256 |
| --- | --- |
| run-07-command.py | `9a248c655a81666d0208a787868d5dd0ec28fbb8aac764643bd6898110352d14` |
| run-10-command.py | `67232ef1c8639207199a6f6dae76b1463131934d2162e2ddc8d8792b861fe9b8` |
| run-10-final-acceptance.py | `d8fdc7b6b0aab683e5d3a1a09651705ae8cf4baf69e4c0aa3347f23f11c317e1` |
| run-10-file-processes.py | `7b3d9424e919588eac6211d783ee61abb3a3e56b77d49515dfc181721c612255` |
| audit-10-final.py | `218b63279c6e5ac57a0befb80f7ea8337503e54382d468e2034eaf40b9863272` |
| collect-10-host.ps1 | `7c85079d24bd1123cfa88c31871fdcb1a3567d2e49fd1bc6b9c2819f757eab7f` |

**历史阶段记录（已被下文最终终态取代）：** 初审时v3实际两产物十轮、两mode全套及最终audit仍pending。本轮不以旧版本通过或作者定向green代替最终同源验收；旧StackOverflow和InvalidArchiveDescriptor证据保留。报告不提升容量、断电耐久性或生产资格。

## 已完成动态证据增量复核

随后独立只读检查`10-final-v3-{app,cli}-processes`：两组各11轮seed/advance与recover配对报告、30个唯一PID/开始时间身份及全部child终态通过核对。聚合reports和observation-reports逐项等于原始stdout JSON，原始stdout/stderr SHA与result一致；普通child均exit0且未超时，两次指定中断均为非零退出。每次recover的前后文件清单相等，五个最终保留数据目录逐项重新扫描SHA/大小/分配大小与记录相等。

每组两次中断的完整整行marker均匹配对应旧/新barrier与digest，记录的killed_pid等于child PID；恢复结果等于实际stdout及预期完整authority。golden确实推进barrier/digest、经济摘要保持，其他三片不变。观察夹具各组500唯一instrument、四路各125及三类业务断言通过；恢复保持accepted8、Unknown1且发送计数为零，逐轮advance发送仅为预期6次，未重发第四片旧订单。当前fixture资源仍在既定小规模范围。

应用artifact SHA为`7da06bc4299bb470bec7bbffb493b099b7137f5337f6a9b0fdd253da1eac8996`，CLI为`6ba20e8ffab304b24a13c68af477df0217c4e9bf264839675f4853ab89e450d0`；均与各自build结果、process identity及当前二进制相等。实际PE stack reserve分别64MiB/256MiB，未扩大应用栈。两个process identity的源码列表和producer依赖均与冻结记录相等；当前114源码及六producer重新计算仍匹配上表。

历史阶段记录：ReleaseSafe先完成624/624；该次复核时Debug终态result与最终audit尚不存在，因此当时未关闭总验收。下文终审已核实后续实际完成结果。本次未运行compiler、测试或最终auditor，未修改src/producer；未发现新增确认P1/P2。

## 最终终态独立复核

当前114源码仍为`f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42`，六producer实际SHA仍逐项匹配冻结identity。十二个最终capture均exit0、无timeout、source/producer漂移0；原始stderr/stdout及memory样本SHA全部核对，消费artifact前后SHA相等。

ReleaseSafe与Debug原始日志各明确`All 624 tests passed.`，每mode实际分别含9个Owner fault、6个拒绝、3个Gateway fault诊断；原始日志SHA与成功result一致。耗时分别2792.9613943秒、5393.1964956秒。四artifact当前SHA、构建result及最终manifest相等：

| artifact | SHA256 |
| --- | --- |
| full ReleaseSafe | `76fee3828db9b17fbb2b89d1dfbd1fd053e7d8c72f0a14daf0a7191dd5dd7255` |
| full Debug | `cb6befc22426ae5fda2bfe0c5913cb07229790cf511c96aa1aee1b63b4a7c02c` |
| app | `7da06bc4299bb470bec7bbffb493b099b7137f5337f6a9b0fdd253da1eac8996` |
| CLI | `6ba20e8ffab304b24a13c68af477df0217c4e9bf264839675f4853ab89e450d0` |

正式audit实际state=passed、570项记录完整、每mode624。七文件Windows封存包identity绑定的183个输入SHA全部重新计算相等，collector实际SHA=`da8ebdf768011ade28a510c74b7d1c20dde46a785442fd3c898d1b969831b21c`。retained-failures的36项与当前Frontier10根及子目录非零result全集相等，逐项SHA/exit核对；包含v1 advance-02、首次Owner拆壳失败、第二次拆壳InvalidArchiveDescriptor及unchanged精确red。预期自有进程终止独立标明，未冒充开发失败或OS故障。

issue10已resolved、map唯一Frontier11，与本轮小规模功能结果相符；已提醒root清理map末尾Not yet verified两条旧概述，避免与新状态矛盾。**Standards终审无剩余确认P1/P2；本阶段实际功能验收与封存完成，仍待root scoped commit。** 未运行compiler/完整suite/最终auditor，仅只读核对；不授予千单、压力、资源预算、目录/断电耐久性、Linux或生产资格。
