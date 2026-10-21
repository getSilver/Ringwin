# 08 checkpoint 基础设施验证

日期：2026-10-21。实现基线：`52d28559`，审查修复：`e0ade48a`，新会话恢复补验：`8fc15f7e`，整数解析容量加固：`d5e449ca`。任务保持 in_progress。

## 授权及边界

用户先确认 [schema 提案](08-checkpoint-design.md)，随后明确要求「仅完成 checkpoint 基础设施，模型验收保持待定」。本轮没有实现研究模型、改变交易行为、部署或交易。08 的剩余运行验收仍阻塞 09b；本记录不是完整 H3 或生产资格。

## 实现

- `python/strategy_state.py`：显式固定字段、tag 和有界数组；8 MiB 总量；整数身份/金额、有理数、finite binary64 bits；冻结目标、阶段/退出、时钟、Unknown/经济引用、信号、模型、监测、标签和随机材料。重复键、浮点 JSON、非规范内容、矩阵/期限/目标/阶段矛盾与容量溢出拒绝。
- `python/strategy_host.py`：跨所 schema 身份与旧两字段示例分开；`portable` 模式从兼容 checkpoint 报告状态，并在完整 cursor 上响应显式 checkpoint 请求。该模式不实现模型输入更新、catch-up 或激活；barrier 超过 checkpoint cursor 明确拒绝，不伪造追赶成功。
- `src/strategy/strategy_host_recovery.zig`：保留旧示例，增加独立 payload 容器编解码及 StrategyStateDigest。Zig 验证独立预期元数据、容器格式、CRC 和内容身份；Python 执行其私有 schema 语义校验。opaque payload 不成为核心经济权威。
- `src/strategy/strategy_host_lifecycle.zig`：请求/响应类型 7/108，校验会话、单调请求身份、帧序号、精确 cursor/版本/下一意图序号，返回内容仍不是持久发布或交易权限。
- `src/strategy/strategy_checkpoint_store.zig`：独占单 Writer、三个明确 control stream；显式初始化与恢复分开。写未被引用的内容槽，提交、seal、发布 snapshot、轮转后，再提交固定 200-byte QSP1 catalog 引用。恢复按该引用核对内容 barrier、元数据、内容身份及状态摘要。只承诺当前已发布版本的保留；不开放任意历史读取，也不自动覆盖其他 owner 的 namespace。
- `python/verify_strategy_host.py` 纳入新 checkpoint 校验和公共 Store 验证；真实 Host 集成增加文件关闭重开和 catalog append 失败场景。

三个 stream 的当前/前代快照缓存及 journal/archive 容量沿用 DurableStore；Store 无法分配 namespace 或保存内容时返回错误，不能驱逐其他 owner 或未解决证据。每个实例的三流拓扑要单独分配 Store 预算，不宣称一个已有八流 Store 还能容纳任意实例。大 payload 的内存和吞吐资格仍未测量。

## 验证命令与结果

环境：Windows 10 build 17763，x86_64；CPython 3.9.18（MSC v.1916 64 bit）；Zig `0.17.0-dev.315+5b647b792`。

| 命令 | 实际结果 |
|---|---|
| `python python/test_strategy_checkpoint.py` | 7/7 passed；真实子进程 checkpoint 返回、完整冻结/Unknown/时钟/标签/随机材料编码、非法内容及容量、阶段矛盾拒绝 |
| `python python/test_strategy_host_bridge.py` | 5/5 passed |
| `python tools/zig-entry.py test src/strategy/strategy_checkpoint_store.zig -O ReleaseSafe --stack 536870912 --test-filter "checkpoint publication keeps"` | 2/2 passed（含 entry）；20 次发布、重复幂等、交替内容槽、内容发布故障不推进 catalog |
| `python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912` | passed；真实 pipe 返回精确内容，Host 未激活，文件重开摘要及 bytes 相同；完整新内容但 catalog append 失败后重开仍选择原发布引用 |
| `zig test src/main.zig -O ReleaseSafe --stack 536870912` | 653/653 passed；进程退出码 0，本地日志 `08-full-suite.log` |
| `python python/verify_strategy_host.py` | 16/16 passed，`strategy_host_product_acceptance=passed`；进程退出码 0，本地日志 `08-host-acceptance.log` |
| 变更文件 `zig fmt --check`、`git diff --check` | passed |

两条集成结果分别报告旧示例 `replay=equivalent` 和新基础设施 `model_replay=not_run`，不能混为真实模型一致性证据。单次冻结状态的编码/恢复没有覆盖 S6-A/B/J/M 的模型运行路径。

用户中断后继续任务时，重新读取两个进程的最终结果，均为正常退出且 exit_code=0；对应 Zig/test/Host 验证子进程已结束，无需重跑已通过的完整验证。Host 集成还实际把关闭重开后的内容送入新一代 Host，比较恢复摘要及再次返回的完整 checkpoint，Host 始终未激活。

16 项产品验收中的容量场景覆盖 normal、gc_exception、slow、crash、recovery，每个场景至少 1,000,000 样本；input_full/rejected/stale/recovery_intents 均为 0。该结果属于既有 Host 合成容量验收，不证明新 schema 的最大 8 MiB payload 性能或真实策略模型资格。完整运行期间容量场景与 Zig 回归并发，不把其延迟数值推广为独占机器性能基线。

## 双轴审查

Standards：无发现；保持 DurableStore、匿名 pipe、私有状态/核心权威及平台证据边界。

Spec：初审发现 Reconciling 前为 Holding 但目标 pending，以及已有退出证据却处于 Holding 的两种矛盾状态；`e0ade48a` 修复，公共 Host checkpoint 回归覆盖两种输入。复审无遗留发现。审查没有把未实现模型列作本轮基础设施缺陷，也没有把基础设施当作整票通过。

## 尚未通过

真实策略模型版本和输入更新；不同 Host 分批/切点重放后的模型、决策、意图和摘要一致性；预热、成熟标签和随机消费连续性；边界数值的真实方向/数量/目标/门槛判断；依赖产物可解析性及核心周期/占用/恢复激活联结；Linux 运行、跨平台数值、断电/HA、性能和生产资格。

S6-L/O 仅有本轮编码、容量和持久引用部分的证据，不将 S6-L/O 整体标为 passed。catalog 的基础设施 publication record 尚不等于 TradingShard 上已确认的完整周期恢复事实。
