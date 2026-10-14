# 06 完整ReleaseSafe当前失败定位

当前冻结身份3cc1586d，见[清单](06-rollback-source-manifest.json)。完整执行日志见[原始日志](06-rollback-full-releasesafe.log)，截至本记录仍在运行，最终退出码由父进程完成后保存；不能将已通过项计为全套通过。

第104项four-shard acceptance在最后固定共享摘要比较失败：旧期望b09266fa1e98725d945f4f57de07c465e78c499bf8f1ed6817b6be99395214a8，实际6d6faae5988291f1a2f920bac2d257fa3eb9ecc5db664daf881adfcca7343c62。

源码four_shard_acceptance.zig:722–751先比较每分片fenced live、journal恢复、checkpoint路径B、轮转路径C的完整CanonicalStateDigest，再比较三份shared summary并断言ownership.count=4；这些断言均通过后才在固定旧摘要处抛FourShardEvidenceDrift。前段财务和账本检查也已执行。新state/journal身份及累计归档承接状态进入摘要，既有共享golden需在保留全部财务/三路径断言的前提下更新。

当前不修改冻结源码，不启动Debug，也不删除失败日志。待本轮548项完整结束，核对全部失败后更新已验证的固定摘要或修复其他问题，重新冻结并执行两模式；该失败轮不能代替最终验收。

## 完整终态与第二项失败

2026-10-14T03:27:25Z完整ReleaseSafe结束：546 passed、0 skipped、2 failed，退出1，91份源码清单匹配无变化；见[退出记录](06-rollback-full-releasesafe.result.json)。原失败日志保留，不计为最终通过。四分片各25 live/25 terminal、初始归档、十轮替换与最终恢复用例完整通过。

第425项公开Owner安全用例在order_history_safety_acceptance.zig:56期望已应用唯一成交20、实际0。用同源码定向Debug复现，见[红日志](06-safety-fill-red-debug.log)和[退出1](06-safety-fill-red-debug.result.json)。原05用例通过；06新增Fill冷历史查验后，主风险候选及首个超时report已占两槽，后续Fill在historyCandidateFor的安全槽检查返回HistorySafetyCapacity，仅持久deferred admission，未经济应用。不能删除累计20断言，也不能以热订单存在跳过全局成交身份历史证明。

修复采用仅Fill的可用证明与原输入原子权威事实：查询可用时校验完整原候选、当前根、时钟和准入后应用，不占用已有两槽；查询不可用仍持久背压。须验证恢复、提交故障及冲突锁存，原候选保持不变。修复实施中，最终冻结两模式尚待。

独立Spec复核确认四分片业务源码相对05未变，经济公式未变；journal身份及新增累计/归档/source状态进入CanonicalStateDigest，已解释共享摘要变化。完整财务和三路径断言均保留，固定golden更新为本轮捕获6d6faae5…34c62，随后仍需定向及完整验收。

## 旧6aaReleaseSafe核对（后因大夹具作废）

旧91份源码冻结6aa4145e，完整ReleaseSafe于2026-10-14T04:08:53Z结束，549/549退出0、清单无漂移，见[旧完整退出记录](06-superseded-6aa/06-final-full-releasesafe.result.json)。原104共享摘要与原公开安全回归（当前426）均完整通过；新增5种同步Fill边界（425）亦通过。后发现旧Gateway仍实际构造40960证明和8192 reservation，违反小规模功能口径；该Debug已主动中止，全体日志/结果/产物移动到06-superseded-6aa保留。中止来源为执行口径，不是断言失败或观察超时，子进程原生退出码未保留，wrapper退出-1。

大夹具现改为100恢复证明、6 reservation/3 position，六处生产guard保持原==与usize总和，生产常量未变，定向Debug22/22退出0。新最终91文件冻结15e3f31f，正在重新验收；旧549/549不能替代这一身份的最终门槛。
