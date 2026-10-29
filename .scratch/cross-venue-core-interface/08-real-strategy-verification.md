# 08 真实策略 checkpoint 验证

日期：2026-10-29。策略基点 `e85edd158667ef1ce9fea21a57bdb7d84236a3a9`；实现 `9502e649`，审查修复 `7f471ecf`。分支 `codex/08-real-strategy-checkpoint`，工作树 `D:\github\Ringwin-08-checkpoint`。本记录补充并取代旧验证记录中“真实模型未运行”的当前状态，保留其历史证据。

## 合同与公共路径

采用用户指定策略分支的真实 v2 组件，不改算法或核心经济所有权。详见[运行合同](08-real-strategy-contract.md)。包内 factory 解析冻结模板，完整 InputRecord 保留类型/schema/cursor/时间存在位及四种原时间；batch 边界不交给策略。回调使用真实 RollingWindow/RollingBaseline、AR1、Filter、LabelTracker、Signal、Monitor 和 Cycle 的公开方法；冻结 Estimator/Calibration 使用同一 codec。非法输入或半次更新失败后禁止保存及重试。

真实 Python 子进程通过 SessionPlan、BeginRecovery、InputBatch、RequestCheckpoint 和 Shutdown 驱动。比较 cursor 0..14 共 15 个切点、整批与逐条分批、新会话恢复及恢复报告后的继续输入；最终完整 QSSC bytes 相同，因而私有状态、QSSD、next IntentSequence 和已决定意图的全部字段一致。重放没有 StrategyOutputFrame，不能借恢复重新发出历史意图。

Zig `Gateway → ManagedHost → Repository → 文件关闭重开 → 新 ManagedHost` 以 v2 初态运行真实组件，持久发布 cursor7；注入新内容完成但 catalog append 失败，重开仍选择原发布。将重开内容直接交新 Host，追赶到14，与连续运行完整 bytes相同，next IntentSequence=5；独立 Metadata、内容身份和摘要检查保持。Host 始终 recovered，未激活。

## 验收向量

| 向量 | 实际证据 |
|---|---|
| S6-A/B | 15个切点、不同分批/会话、继续输入、文件发布后重开追赶；重复帧、缺口、旧会话、跨屏障及记录计数错误拒绝 |
| S6-J | 切点保留真实模型预热/滚动窗口、filtered协方差和待成熟预测；到期与缺失标签实际推进。两次跨Host checkpoint重复同一监测窗口，全部监测字段保持；缺失/未成熟窗口不得提高健康计数或清除原状态 |
| S6-M | 9组冻结配置：679999/680000/680001 ppm × 持仓目标40000000 atoms上下1；实际概率判定及1019/1020/1021 tick退出计算跨Host恢复保持，原意图身份/数量/价格及首次退出cursor不变 |
| S6-L/O 编码部分 | 子进程拒绝非有限值、负协方差、窗口/标签/组件超容量、冻结依赖不符、阶段回退、意图序号矛盾及评估预算越界；内容损坏、错误预期元数据、未提交发布及缺失尾部均失败关闭 |
| 时间证据 | 完整9字段InputRecord精确相等；子进程拒绝与样本矛盾的有效时钟字段，恢复不丢原始时间包络 |

实际模型在线更新为确定性标量运算，场景/校准为冻结依赖；没有在线随机生成器可重新播种。研究 Protocol.seed、试验及holdout额度保持由原Study journal拥有，完整Python回归涵盖其重启/预算。没有为恢复清窗口、重新拟合、补领研究额度或更换seed。

## 最终命令与结果

环境：Windows 10 build17763 x86_64；CPython3.9.18 MSC v.1916 64bit；Zig `0.17.0-dev.315+5b647b792`。

| 命令 | 结果 |
|---|---|
| `python -m unittest discover -s python -p 'test_*.py'` | **238/238**，230.660s，exit0；含最终8项真实Host测试，日志 `.scratch/build/08-python-final.log` |
| `zig test src/main.zig -O ReleaseSafe --stack 536870912` | **814/814**，exit0；日志 `.scratch/build/08-zig-full.log` |
| `python python/verify_strategy_host.py` | **27/27**，`strategy_host_product_acceptance=passed`，exit0；日志 `.scratch/build/08-host-product.log` |
| `python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912` | 产品验收第24项通过；真实模型 `published_cut=7, barrier=14, file_reopen=exact, intent_sequence=5` |
| `python -m compileall -q python`、变更Zig文件 `zig fmt --check`、`git diff --check` | 通过 |

中断后已从三个原执行session收取最终结果，均exit0，相关进程已结束。没有因中断重复运行已通过的验证。产品验收第1项在审查修复前启动，记录6项Host测试；新增2项时钟/监测测试已定向通过，随后最终Python全量238项覆盖最终8项；第24项集成使用最终时钟包络代码并通过。Zig全量源文件不受这两项Python修复影响。

产品容量矩阵 normal/gc_exception/slow/crash/recovery 每分布至少1,000,000样本，input_full/rejected/stale/recovery_intents均0。它仍是既有合成Host负载；运行时与其他检查并发，不能推广为真实模型或8MiB最大payload性能资格。

## 摘要样例

从真实子进程完整输入/返回内容计算，cursor14、next5：

- 输入fixture SHA256：`1758fb7e0c6256ea8dc4f890e5635e096ed4a7ba1787d84871bdc2edd8e77555`
- 初态QSSC SHA256：`770c1715e9a6cb530bc59065d27a3cbf2b5216004b0f3a8157c377662774737c`
- 最终QSSC SHA256：`2fbf180ac6b250f8b4feef1e579706bd0163166a7459dc29d9ec6b87135d1d18`
- StrategyStateDigest：`6b94001e629a42264fd73b9c551babd9c850b60acac32e1f5e01e4ee08f6de32`

## 双轴审查与边界

按code-review技能由独立Standards/Spec审查，固定范围 `e85edd15...7f471ecf`。Standards无发现；Spec初审两项P2：丢失原时间字段、重复监测窗口缺少Host路径证据。`7f471ecf`修复并新增公共路径测试；两轴复审均无遗留发现。

08按以上Windows本机离线范围完成，不等于完整S6-L/O、H3或生产资格。输入是显式离线样本与不可变Facts引用，不是生产canonical日志或Venue codec。跨平台/其他Python构建、跨机可信时间、最大payload性能、断电/HA及真实交易未资格化。在线随机模型未纳入支持；Study研究journal不属于Host checkpoint。核心占用、账户对账、新HostActivationBarrier及授权联结仍归09b，09/10及来源策略spec不关闭。没有部署或真实/Demo下单。
