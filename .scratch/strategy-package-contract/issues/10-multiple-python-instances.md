# 10：多个 Python 实例共存与共享 Host 生命周期

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 Python 实例 checkpoint 与重启恢复](05-python-checkpoint-recovery.md)、[06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)、[08 代码替换与 ForwardRollback 创建 StrategySuccessor](08-successor-rollback.md)
Parent: [模块地图](../map.md)

## Question

如何运行多个Python实例并准确处理目标替换、共享Host故障和恢复的影响范围？

## What to build

验收同定义不同配置和多个定义共存，落实加载组织、内存计量及共享Host生命周期，向Web呈现实际影响范围。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] 同定义不同配置及多个定义可按批准放置运行；模块解析符合各包清单，实例私有状态、输出身份和checkpoint不串用。
- [x] 明确内存计量口径、包上限到进程预算的映射和Host放置，实际执行所声明限制，不要求进程内逐实例硬隔离。
- [x] 策略/checkpoint聚合摘要按规范生成并绑定实际集合，不截断完整包摘要或使用占位值。
- [x] 目标替换仅改变指定实例代码/配置；需要重启共享Host时展示全部受影响实例，并按既有会话失效路径撤权和恢复。
- [x] 一个Host异常、超时或超内存不阻塞核心及其他Host；验证受影响实例恢复后的身份、序号与权限，没有自动复权。

## Answer / 实现证据

2026-11-01 完成 Windows 离线实现及验收，实施提交 `3dabcab2`、修正提交 `95c0c043`。

- 现有 Web 与签名安装路径支持批准放置；同 DecisionDomain、精确相同锁定运行时的最多16个实例共享真实解释器，不同域或运行时使用独立进程。各包同名模块、实例状态、完整组输出身份与 checkpoint 独立。
- Windows 共享限制计量为包含适配器/解释器的 Job 总提交内存，上限为成员包预算之和；真实多进程预算与共享内存超限均有反向验收，不宣称进程内逐实例硬隔离。策略与 checkpoint 成员集合以规范 JSON、域分离完整 SHA-256 绑定，并保留既有实际 checkpoint 验证。
- Web 显示进程成员、预算、摘要及整个 DecisionDomain 的切换影响。替换非当前目标先复用 Keep 激活选择目标，再执行原 Successor 路径；只变更目标绑定，其余成员保留原包、配置及持久仓库。共享故障撤权，恢复保留身份及序号，停在无权 Ready；仍须各实例显式 EnableTrading。
- 修复并发管理双锁死锁、慢候选持父锁、并发停用状态覆盖及切换等待窗口。三个有界真实 Web 子进程回归覆盖双管理写、独立 Host 在候选超时期间继续处理输入，以及并发停用后的持久 Stopped；KillSwitch 保留失败关闭边界。
- 最终 Python **341项、327通过、14平台skip，exit0**；核心 ReleaseSafe **825/825，exit0**；发布构建 **9/9**、节点构建 **3/3**，UI/静态检查通过，Standards/Spec 最终复审均 **0项**。真实共享进程、双核心绑定、完整组输出及迟到拒绝、目标参数/代码转换、原仓库恢复与其他 Host 故障隔离有专项和全量证据。

完整范围、源码/二进制身份、首次失败与修正及最终日志见[10验证说明](../evidence/10-validation.md)。Linux 共享进程总预算路径尚未实现并明确拒绝；既有 Linux 单实例资源缺口、真实 Venue、节点断电/热备耐久、部署及生产资格不由本次 Windows 离线结果关闭。10 resolved，11 可接手但未认领；地图保持 open。

