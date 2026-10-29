# 08：真实策略运行接线与资格范围

日期：2026-10-29。来源：用户要求使用 `spread-arbitrage-strategy-python` 分支的真实策略完成 08 剩余任务。实现基点 `e85edd158667ef1ce9fea21a57bdb7d84236a3a9`；在独立 worktree 实施，主目录及其他分支不参与修改。

## 已确认的 schema

用户指定的策略分支已实现 `arbitrage_checkpoint.py` 的显式组件 schema v2；沿用该格式，不把真实组件解释为 v1 语义夹具，不作隐式迁移。算法与字段冻结依据为该基点的 `arbitrage_baseline.py`、`arbitrage_state_space.py`、`arbitrage_signals.py`、`arbitrage_admission.py`、`arbitrage_cycle.py`、`arbitrage_maker.py` 及其 checkpoint codec。v2 保留完整冻结依赖摘要、模型窗口/filtered 协方差/标签、信号与监测、Admission 关联、原计划、阶段、期限、退出原因及 IntentSequence。

`strategy_components_v2` / `baseline_binary64_v1` 和状态空间算法版本、binary64 bits、有理数/整数以及 QSSC/QSSD 均沿用现有编码。v1 和旧 accumulator 示例继续分开。最多 64 个组件、窗口 3,600、标签 256、payload 8 MiB；每个模板还保留自身更小的容量。多周期组件必须具有一致的实例级下一 IntentSequence；不一致失败关闭，不能分配互相冲突的身份。本次不新增多周期序号分配器。

## 运行公共接口

策略包入口可调用 `strategy_host.main(runtime_factory=...)`。factory 从包内已认证且可解析的冻结模板创建 `ComponentRuntime`，必须独立指定 registry、实例、定义、配置、schema 及其版本的预期身份；IPC 不能指定模块名、方法名或反序列化任意 Python 对象。缺 factory 时只保留原有静态 checkpoint 行为，不能假称已追赶。

`ComponentRuntime` 使用现有组件 `restore`，把每个已准入输入记录的类型、ShardSequence 和自有 bytes 交给包内确定性回调。回调只能更新策略私有组件；不接收批次边界。窗口/模型/经济计算仍调用真实策略公开方法，Host 不实现替代公式。整个批次的边界、CRC、会话、批序、记录顺序/数量/版本/容量先校验，再运行回调；不能跨过指定恢复屏障。空订阅覆盖可以推进 cursor，但不能制造观测。

每条记录完成后验证私有状态及下一意图序号；失败会毒化整个 runtime，禁止从部分更新状态保存或重试。checkpoint 仍在完整 batch cursor 上请求/返回。BeginRecovery 期间输出关闭，恢复报告后也只允许继续输入及保存状态；此入口不接受 ActivateStrategy、不发布交易意图。实际 Cycle 已决定的意图及序号在 checkpoint 中逐字段比较，不能把无输出误称为未作决定。

Host 只在当前会话/连续控制序号上接受单调 checkpoint 请求。Zig `ManagedHost` 已以独立预期 Metadata 校验 v2 opaque 容器，Repository 已绑定精确版本/内容/摘要；无需放宽核心编码或升级 journal/registry。基础设施 catalog 仍不是核心周期事实，激活与核心占用联结归 09b。

## 可复现输入与平台

`test_arbitrage_host.py` 是离线资格入口：数值输入为显式有界样本，经济输入为固定内容摘要引用，解析到测试包内不可变 Facts 及冻结估计器。fixture 不是生产 canonical 日志、行情适配器或 Venue 证据；不能用于生产投喂。两份 `src/testing/fixtures/arbitrage_host_*.json` 绑定 v2 初态及上述输入内容，Zig 使用真实 Gateway 编码、ManagedHost pipe 与 Store 文件路径验证恢复。

现有模型使用确定性标量更新和冻结场景，在线更新不调用随机生成器。Estimator/Calibration 的冻结内容由组件依赖摘要绑定，恢复不能重新拟合、抽样或换 seed。研究模块的 Protocol.seed 与 Study 试验/holdout 预算继续由独立研究 journal 拥有，不搬入 Host，不因 Host 恢复清空或重建；完整 Python 回归包含该 journal 重启/预算测试。本次没有资格化新的随机在线模型。

运行资格只报告实际 Windows x86_64、CPython 3.9.18 MSC v.1916、Zig 0.17.0-dev.315 的精确结果。Linux/其他 Python 构建、真实输入日志、最大 payload 性能、断电及生产资格仍独立验收，不由当前模型通过推导。
