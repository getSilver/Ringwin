# 10 Standards review

基线：`4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。审阅`git diff 4ea4c3ee -- src`、两个未跟踪的`windows_capacity*_acceptance.zig`、`run-10-command.py`、`run-10-file-processes.py`、`run-10-final-acceptance.py`及`collect-10-host.ps1`全文。

标准来源：AGENTS、CONTEXT、domain/issue-tracker规则、ADR0004/0010/0011/0013、Zig skill及十二项Fowler smell baseline。已显式搜索，无CONTRIBUTING、CODING_STANDARDS或嵌套AGENTS；仓库规则优先，未重复报告fmt可处理事项。

**Hard：无剩余确认P1/P2。Judgement：无需要阻塞的P1/P2。**

初审发现的P1应用编译错误已在源码修复：原`windows_capacity_acceptance.zig:112`调用`authorityForTesting`，非test应用命中`failover.zig:766`的compileError。当前115行改为夹具局部synthetic authority；未删除或绕改该guard，355行报告仍固定`synthetic_fencing=true`、`production_qualification=false`。本审查未启动完整套件；实际应用重建结果由最终验收单列，不能以源码修复冒充编译成功。

Owner/Gateway/FileAdapter及32MiB scratch均由allocator持有；恢复先在未发布Owner完成，再验证公共经济、账本、占用、游标与digest。fixture模拟Venue与生产dispatcher隔离；未改production_contract或授予平台资格。根路径要求absolute，seed只接受空shard目录；进程runner只创建新prefix目录，无递归删除，terminate仅作用于其Popen子进程。故障测试cleanup只针对新建tmpDir；失败保留原目录。真实字节破坏与命名hook分别报告，未知schema/artifact测试经Store认证后由Core拒绝。

计数范围：四片seed合计live5，常态advance瞬时至多live6、terminal1，终态归档后恢复live5；fault夹具live2、terminal0，均低于100。顺序十轮不累计为并发。目录flush失败及断电语义属于已知基线限制，须按10-file-semantics独立披露，未将其误报为此次新增生产路径缺陷。

审阅时workload SHA256为`4fbd5fd4aabd083ad95e6f9b6eee94618b29462cfe7a14af03c4bc1d5e8fe292`，fault SHA256为`492dec68c11b50198ea62c5b6f12f41ddc7445eb534994b0162d69c61b4b4ff2`。源码仍开发中；最终冻结如变化需复核差异。仅写review文档，未改src或运行全套。
