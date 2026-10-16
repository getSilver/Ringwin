# 10 runner Standards 补充复核

2026-10-16。范围为当前 `run-10-command.py`、`run-10-final-acceptance.py`、`run-10-file-processes.py` 及其 `run-07-command.py` 身份依赖；不重复审计故障Zig模块，不以本报告代替最终冻结候选的实际运行。沿用AGENTS、CONTEXT、ADR0004/0010/0011/0013–0016及本地证据保留规则；按十二项smell baseline判断，没有因工具格式、有限脚本重复或既有公共接缝导航新增硬性问题。

**前次五项P2已按当前串行、默认非优化Python运行路径复核关闭，未发现剩余确认P1/P2。**

1. Capture默认显式deadline为10,800秒，可用正整数环境配置缩短；循环超时只终止自有Popen句柄，结果保留`timed_out`、PID、时间及退出码。启动和执行循环异常记录`capture_error`，不再因正常spawn失败跳过result。真实1秒timeout和不存在exe的native probe均有非零退出结果及原始日志。
2. Final runner将每个build产物SHA保存到`built_artifacts`，普通测试、app、CLI及进程runner消费前核对，完成后再核对。ReleaseSafe resume读取并验证原build的命令、成功状态、源码清单、artifact和两份日志hash，随后才消费既有exe；不把当前路径内容的事后hash冒充构建时身份。
3. Capture在启动前检查全部四类既有label文件，存在任一即拒绝。Final既有identity只允许显式resume且要求完整identity相等，不覆盖该identity；process evidence目录仍拒绝复用。已核对existing-prefix probe的原success result SHA确实未变。
4. Step golden现在先validate，要求shard0 barrier推进、canonical digest改变、economic digest不变，其余三片权威状态相同；golden恢复与两个kill恢复均validate并逐字段比较权威状态。kill marker由对应seed/golden的确切barrier及64字符hex digest组成，使用splitlines后的整行匹配；只对本次Popen子进程执行terminate，并要求观察到非零中断退出。正常recover仍比对前后实际文件名、长度、SHA及allocation清单，没有用父进程内存快照替代子进程恢复。
5. Final冻结四个producer文件SHA并在每阶段前后校验；capture记录自己与基础manifest依赖的前后hash；process runner冻结自身、capture及基础manifest依赖，并检查host metadata。Zig/build manifest仍独立在阶段前后核对。脚本身份与业务源码身份分别保留，不把Python改动藏入不变的Zig树hash。

只读核对 `10-capture-probe-audit.json` 与其实际result/log/stdout：existing-prefix原result hash相等；timeout为`timed_out=true`、exit 1且有PID；spawn failure为`capture_error=FileNotFoundError`、exit 1且PID为空；两者log/stdout hash及producer/source mismatch字段均一致。未重跑完整套件，未修改任何runner或源码。

本次审阅身份（SHA256）：

| 文件 | SHA256 |
| --- | --- |
| run-10-command.py | `67232ef1c8639207199a6f6dae76b1463131934d2162e2ddc8d8792b861fe9b8` |
| run-10-final-acceptance.py | `24cd26f5dac09746beb31d8207100eb9a32b42fced5a2968ec1fa956eba9a95f` |
| run-10-file-processes.py | `4df7adb7381d7a0a133c12263b5a4dcf5b3440989df8320f92b23e57c61f9fe2` |
| run-07-command.py | `9a248c655a81666d0208a787868d5dd0ec28fbb8aac764643bd6898110352d14` |

mixed/500 CLI扩展仍在开发；报告schema、字段、物理数据及最终producer身份必须在冻结后与实际结果重新对应。本补充仅关闭上述runner审计发现，不授予容量、压力、资源预算、断电、平台或生产资格。
