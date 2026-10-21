# 04 离线验证记录

2026-10-21。任务：[04 Host 完整 IntentGroup](issues/04-host-intent-group.md)。合同：[输出、身份与兼容](04-host-group-contract.md)。

## 基线与范围

最终实现基于已提交的 02 `8ea7accb`；中断期间 01/02 独立完成，04 保留其领域决策及深度实现。用户明确允许将已有源码目录迁移与 04 一并提交。迁移包括职责目录、统一独立编译入口、相关脚本/文档引用及既有 CONTEXT → GLOSSARY 更名；未将无关的旧验收日志删除或 synthetic-store 纳入。

环境：Windows、Zig `0.17.0-dev.315+5b647b792`、测试栈 `536870912` bytes、Python 3.9。04 使用 journal 41 / state 45 / registry 39；Canonical 行情 schema/codec 保留 02 的 14/12。没有运行网络交易、部署或 Demo 下单。

## 命令与结果

| 检查 | 结果与日志 |
|---|---|
| `zig test src/main.zig -OReleaseSafe --stack 536870912` | **652/652 通过**；[完整日志](../build/task04-full-releasesafe.log) |
| `zig build` | 通过；[构建日志](../build/task04-build.log) |
| `python python/verify_strategy_host.py` 最终串行复验 | **14/14 通过**，退出码 0；[日志](../build/task04-host-product-final.log) |
| `python -m unittest discover -s python -p test_strategy_host_bridge.py` | **5/5 通过** |
| Debug 真实 Host 集成 | 通过，包括完整组、会话更换、容量回滚及文件重开恢复 |
| `python tools/zig-entry.py build-lib src/strategy/strategy_host_ipc.zig -dynamic -OReleaseSafe '-femit-bin=.scratch/build/task04-ipc.dll'` | 通过，仅合成测试 ABI 构建；不授予 Python 共享内存能力 |
| `zig fmt --check src build.zig`、Python 编译、PowerShell 语法、`git diff --check` | 通过 |

主回归的固定轨迹摘要包含 journal schema。先从 `git archive HEAD src` 的独立原布局副本验证 02 的五条固定轨迹 **2/2 测试通过**，再对 schema 41 保留原经济断言、屏障与独立重放相等检查，更新五条固定摘要及四分片共享摘要。未删除或放宽经济断言。

主回归后仅调整独立 Host 故障验收的夹具初始化顺序，该文件不属于 `src/main.zig` 的主回归导入；该调整由最终 Host 产品验收覆盖。

## 公共接缝证据

`python/strategy_host.py → ManagedHost pipe → Gateway.ingest → Decision.corePayload → TradingShard.applyStable` 一次传输两个账户的两个有序成员。成员占连续序号，原始完整组及授权包络进入 canonical input。所有组路径保持预留、Order 和 OrderCommand 为零；合法新组以 joint_admission_unavailable 整体拒绝并持久记住全部身份。

独立集成验证：

- 合法完整组、旧单意图原风险路径、同组重复和重叠序号冲突；重复无新事实，冲突不部分记住新成员。
- 半帧、CRC-valid 半组、不连续成员序号、超长 count、目标缓冲容量和 `u64` 序号溢出。
- 旧会话、未知 registry、冲突策略/配置/激活，不消费当前策略业务身份。
- 完整授权组的 stale/cursor 拒绝一次消费全部成员；刷新时间或包络不复用已消费身份。
- 同内容的新 batch/cursor 仍为重复；恢复快照后通过 host_activation_revoked / host_activated 更换实际会话及激活，再提交同一业务组，仍无新事实。
- journal sealed 写入失败时 CanonicalStateDigest 不变；恢复可写 journal 后原候选可重新提交。经公共输入填满 Trace 后，完整组拒绝失败不留下半组身份。
- stable replay 与快照恢复摘要相同；FileAdapter 按 append → commit → seal → publishSnapshot → close → reopen 恢复，日志重放及快照均恢复同一摘要与 **8 个已消费成员身份、0 个命令**。

文件结果保留于 `.scratch/build/task04-store-*`。这些是本机合成数据，不证明断电、Linux 运行或 HA 资格。

## 红绿与审查

初始完整组接缝在 accepted_group 尚未实现时编译失败。新增“相同业务组刷新 batch/cursor”回归先发现旧实现将整个授权包络计入业务指纹，导致 barrier 从 28 增至 29；改为完整业务 SHA-256 与独立持久授权包络后通过。会话/激活仍须独立校验，未放宽授权。

首次并行验证中，Host 产品验收第 12 步报 HealthyStrategyWasNotIsolated；单独运行该步骤通过。受控在无关 fault fixture 初始化处增加 120 ms 等待，可稳定复现 **stale、elapsed=340670700 ns、trading_enabled=true**。将该夹具准备移到健康输入发布时间之前，同一等待复验通过；最终移除等待和 DEBUG 日志。该测试不再把初始化成本误计入健康输出新鲜度，产品 100 ms 门槛不变。复现证据：[红](../build/task04-fault-delay-red.log)、[绿](../build/task04-fault-delay-green.log)。

最终串行 Host 产品验收第 12 步通过，第 14 步 normal / gc_exception / slow / crash / recovery 五种场景各超过百万样本；rejected、stale、recovery_intents 均为 0。最后输出 `strategy_host_product_acceptance=passed`，已确认进程退出码 0。该本机容量证据不升级 Linux 或生产资格。

code-review 两轴独立审查并复核最后增量：Standards **0 项违规、0 项剩余气味**；Spec **0 项剩余发现**。Standards 的 Gateway/核心职责建议已处理：Gateway 返回类型化 Session，核心不重复解析 IPC 字节偏移。

## 限制

04 只完成 I2 的完整传输与身份入口部分。账户配置及路由资格、共同资金准入、周期占用和发送权限仍归 05a/05b 及后续执行票；来源 spec 不修改、不关闭。没有新增风险权限、Unknown 重发或任何线上资格。
