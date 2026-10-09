# 02 分片屏障改造证据

日期：2026-10-09。业务实现与最终回归基线：`283f2406`；Git src tree identity：
`b2bfe109976fc2426eb2f773b47c888c094d6352`。编译器：`0.17.0-dev.315+5b647b792`。
测试栈显式为64MiB，不能作为生产栈或容量测量结果。

## 实现

`Trace.last_sequence` 与驻留 `len` 分离；永久权限、风险引用、Host、策略游标、
快照及恢复使用 `authoritativeBarrier()`。按全局序号 `factAt()` 查找事实，缺失时不能发送。
本票仍保留从起点开始的完整256条窗口，并验证连续序号与新旧计数等价；满窗口及
u64溢出均返回错误，不提交部分状态，不清空历史。

journal/state/registry切换到31/35/29；StateDigestV6保留完整有序Trace、当前权威状态及
canonical ingress顺序，增加独立全局屏障绑定。旧schema拒绝，SemanticAuthorityDigest
用途不变。见 [ADR0011](../../docs/adr/0011-use-global-shard-barriers-and-ordered-history-continuation.md)。

消费者盘点覆盖整个src。外部剩余16处`trace.len`仅为：账户协调无操作比较2处、
Demo驻留容量3处、benchmark容量/基线/事实计数5处、fixture遍历/显示4处、
Windows拒绝事实的前后长度与下标2处。核心剩余引用是数组切片、驻留扫描、
快照清零、完整窗口摘要和新增事实分组，不再用长度分配永久身份。

旧benchmark的Trace清空被移除，改为每轮独立完整fixture并通过公共snapshot输入衔接
行情源序号；它只测独立样本，不证明持续运行。保留genesis后的公共快照/恢复检查通过。
由新schema和摘要域导致的固定摘要变化已更新；业务数量、资金、风险及独立重放断言保留。

## 检查

在本工作树运行：

```powershell
zig test src/main.zig -O Debug --stack 67108864
zig test src/main.zig -O ReleaseSafe --stack 67108864
```

最终两种模式均426/426通过，见 [Debug](02-final-full-debug.log) 与
[ReleaseSafe](02-final-full-releasesafe.log)。原始整套Debug曾425/426通过，唯一失败为旧的
四分片共享摘要常量，见 [未修订摘要时的结果](02-full-debug.log)。三条实际恢复路径的
业务与摘要一致断言在旧常量失败前已通过；更新后 [定向检查](02-shared-summary-debug.log)
及整套回归通过，未删除或弱化原断言。

新序号篡改检查先红后绿：校验和与摘要均重算过的非连续Trace，旧实现接受，新实现拒绝。
保留 [原始工具输出节选](02-red-excerpt.log) 与 [核心定向结果](02-core-targeted-checks.log)；
节选不是完整原始日志。还覆盖伪造独立计数、旧状态schema、公共快照/尾部重放、满窗口、
溢出及失败后摘要/屏障不变。既有排列测试仍区分规范审计顺序与语义收敛。

消费者定向结果另包括：轨迹Debug2/2、Demo Debug3/3和ReleaseSafe3/3、cutover9/9、
Gateway8/8、独立benchmark1/1；对应同目录`02-consumer-*.log`。
`zig fmt --check`对修改Zig文件及`git diff --check`通过。

zig build -Doptimize=ReleaseSafe 构建退出码0，stdout/stderr为空；见 [构建日志](02-build-releasesafe.log) 与 [构建身份](02-build-metadata.json)。artifact SHA256为 53cdd88c771289bac53b69246a7b23b83b521c5d186166e057183fd5720eecc9；这是本地离线构建，不是平台或Venue资格。

## Standards

GPT6.1Sol、中等强度独立审查，基点e1f84280，主提交d0b977f7及最终修订283f2406。
一项发现：Demo两处数组容量判断错误迁移至全局屏障；已恢复使用驻留len，与第三处一致。
无其他规范或可操作代码异味问题；有界线性检查标注了256窗口上限与后续实现归属。
四分片固定摘要修订经审查确认仍保留独立恢复比较，没有用同一实现重算期望值来替代业务断言。

## Spec

同模型/强度独立审查未发现剩余实现阻塞项。全局屏障、所有权、计数等价、溢出、
schema与公共恢复检查满足票02阶段；本票不启用轮转。最终完整Debug/ReleaseSafe结果
均已补齐，旧失败日志保留。

总结：Standards原1项已修正；Spec无剩余阻塞项。票03仍需实现并验证有序历史承接、
检查点/manifest轮转、归档根和所有提交/删除故障边界。票04–12及千单负载、资源预算、
Windows/Linux文件容量和所有生产资格均未完成。
