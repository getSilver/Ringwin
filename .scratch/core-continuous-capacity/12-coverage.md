# 12 功能覆盖与源码谱系

本轮只封存2026-10-14用户确认的小规模功能范围：每个夹具跨全部分片live和terminal分别不超过100，不执行千单或压力负载。历史事实累计、纯数值边界和观察组合数不当作同时订单数或吞吐资格。1024 live/分片、100000完整生命周期、资源/磁盘/延迟预算仍为未测设计参考。

## 共同基线及平台边界

共同基线为115份源码/构建文件，SHA256 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`，Zig `0.17.0-dev.315+5b647b792`，journal/state/registry=39/43/37、Core artifact identity=1、seed=0x20261008。配置与固定输入保存在源码包及workload，配置版本与业务摘要也进入报告。

- Linux：票11的v6完整ReleaseSafe/Debug各623 passed、1指定IPC skipped、0 failed；应用/CLI各十轮30新进程、物理数据与完整authority审计已完成。数据实际位于WSL1/lxfs，不能把Windows交叉构建当作运行结果。
- Windows：票12从上述完全相同的源码重新构建应用/CLI及受影响测试，逐项绑定源码、编译器、producer、PE、构建参数和消费SHA。`12-final-v2`的16个阶段、333项受影响Debug测试及60个新进程全部通过，最终audit通过；源码包121项与6个PE产物逐项验证。
- 票10的完整Windows624/624属于历史源码f1e1a54a，保留其原始身份；不改称当前源码全量通过。与当前源码的11份差异逐项列于12 identity。Linux专有FileAdapter/离线工作线程、共享File夹具、旧目录夹具、IPC测试能力探针和两个旧Owner测试栈，以及私有成交测试比较修复均纳入受影响验证。
- 票12不改变任何Zig业务源码。Windows重验范围是Native file八项、整个venue-fill模块及依赖、两个旧Owner公共用例；兼有实际应用/CLI离线入口、各十轮30进程和重新读取实际文件。其当前计数不替代历史全量的原始身份。

## 01–11 逐项义务及当前证据

| 票 | 已闭合的功能/合同 | 当前公共入口及证据 | 保留范围 |
| --- | --- | --- | --- |
| 01 | 500组合/三类别/4组路由、累计状态与保留合同、全局屏障及完整摘要演进、耗尽/查证语义 | [容量合同](capacity-contract.md)、[基线容量矩阵](capacity-matrix.md)、[01证据](01-evidence.md)，后续02–11实际实现及回归 | 矩阵是01时的源码盘点，不能把旧容量常量当成当前配置；速率/预算/物理配额是合成设计参考 |
| 02 | 永久屏障与内存Trace下标分离、权限/策略游标承接、旧schema拒绝及有序恢复身份 | `TradingShard.apply/snapshot/restore`、`trading_shard_tests`、[02证据](02-evidence.md)，当前完整Linux套件 | SemanticAuthorityDigest不代替CanonicalStateDigest；格式不支持静默降级或best-effort迁移 |
| 03 | 输入提交→checkpoint→segment/manifest→snapshot→tail恢复、替代证据先持久再回收、缺段/混合/损坏失败关闭 | `demo_authority`、`durable_store`公共测试，100轮及90个Owner/File边界；[03证据](03-evidence.md)、当前两平台文件进程链 | 确定性hook不称真实设备故障；进程SIGKILL不称目标机掉电 |
| 04 | 500个独立Venue×产品×Instrument观察、选择性交易、账户/Instrument隔离及恢复 | `core_observation_capacity_acceptance`及`windows_observation_file_acceptance`；实际四路合成三类别、100 selected live；[04证据](04-evidence.md)及10/11/12 File记录 | 历史04的128选中旧样本不计作当前≤100口径通过；四组路由不等于新增第四家协议或真实在线资格 |
| 05 | 订单/intent/command/dispatch终态归档、稳定命名空间、完整冷查证、重复无副作用/冲突关闭，accepted/Unknown不被清槽重发 | `order_dispatch_archive_acceptance`、`order_gateway_archive_acceptance`、`order_history_safety_acceptance`、[05证据](05-evidence.md)；File十轮 | 有风险或未完成查证的身份继续pin；不重置全局序号 |
| 06 | 唯一canonical Fill与费用承接、完整历史证明、微量/多资产记账、report/Fill顺序与恢复 | `fill_archive_acceptance`、`venue_fill_recovery_acceptance`、`TradingShard.apply(CanonicalEvent)`、[06证据](06-evidence.md)，当前Debug及Windows受影响模块 | 保持OMS exchange cumulative与独立canonical Fill累计分工，不以净额掩盖重复/溢出 |
| 07 | funding、完整ledger、独立累计与对账历史、多窗口归档、迟到/冲突/缺归属处理 | `funding_archive_acceptance`、`reconciliation_archive_acceptance`、`native_economic_reconciliation_acceptance`、[07证据](07-evidence.md)；完整经济/ledger/digest恢复 | 不能用镜像错误的本地累计自证；未闭合证据留在Suspense或RecoveryOnly |
| 08 | 控制/gate/latch/fence历史、单Writer协调、forced source/分配/ledger/ack闭合、共享路由及token/generation高水位 | `control_*_acceptance`、`coordinator_*_acceptance`、`forced_archive_acceptance`及[08证据](08-evidence.md)；当前完整套件及File共享账户 | 未完成/仍引用的事实不回收；归档/恢复不延长lease或授予交易权限 |
| 09 | 四Owner均衡/热点十轮、混合生命周期、账户ceiling、安全背压余量、纯计数边界、恢复零发送 | `continuous_capacity_acceptance`、`continuous_account_acceptance`、`continuous_backpressure_acceptance`、[边界盘点](09-boundary-inventory.md)及[09证据](09-evidence.md) | 1024/1025等纯数值检查不是千单负载；不测100000生命周期、压力或生产栈预算 |
| 10 | Windows真实File、两产物十轮/新进程恢复、完整authority、故障/格式身份拒绝、资源与失败保留 | [10证据](10-evidence.md)、原Windows交接包；当前共同源码的12补验、333受影响测试通过及两组各五个实际数据目录审计通过 | 历史目录flush error5，目录/断电耐久性未合格；原完整套件不伪装为当前完整套件 |
| 11 | Linux真实File同一业务链、完整authority及零重发、Linux同步探针、新进程/物理恢复与独立交接 | [11证据](11-evidence.md)、[独立Linux包](11-final-v6-linux-evidence/summary.md)、84项audit及当前两模式完整结果 | WSL1唯一IPC memfd ENOSYS明确skip；目录fsync成功951次不等于目标设备/断电或生产资格 |

## 不以空循环替代业务

主File链含四片不同归属、共享账户ceiling、partial/filled/pending-cancel/resting/accepted/Unknown、两品种开平与独立对冲的非零经济/费用/ledger/占用。十轮按持久next-order/next-command继续，不清空身份或重置序号；另一个真实File夹具覆盖500组合、部分组合做市与合成资金费/跨Venue类别。恢复比较完整报告与CanonicalStateDigest，并实际读取路径/长度/SHA；经济摘要不能单独代替恢复身份。发布前后终止只证明指定Owner完整旧/新状态，其他Owner保持原状态，不声称跨片原子事务。

共享源码的固定测试还覆盖历史事实多窗口回收、缺证据pin、查询超时/错误、输入未应用/零发送、重复/冲突、计数加一和schema拒绝。累计1024条私有输入、12000摘要等固定历史功能用例不表示1024 live订单或吞吐压力，也不据此授予容量资格。

## 资源与失败的报告口径

Windows GetProcessMemoryInfo与Linux /proc/PID/status记录直接子进程，采样RSS与OS报告peak分开；WSL1 VmHWM=0为不可用。日志logical bytes可测，allocated bytes仅报告可用的常规文件观测，Linux可能缺项或在内容不变时变化。队列仅末端resident样本，实际栈峰值、瞬态水位、物理索引成本、apply/commit p99、生产吞吐及预算均未测。

历史失败、漂移、未完成候选、panic/segfault及其挂起诊断保留原始结果，不因后续通过而删除。12包的nonzero清单也包含刻意SIGKILL/负向探针，必须按原场景分类，不能全称真实故障，也不能全称通过。所有资格以精确被测平台/源码/产物为界。

2026-10-18续验时发现12-v1停在应用第8轮之后，advance-09的stdout/stderr为空且无result；外层没有完成记录、验证进程已不存在，原因未建立。其98个原始引用及未执行范围另见[中断候选目录](12-interrupted-v1.json)，该JSON的SHA256为`78819b1004669cd210d3c4c4f3367694635797283c332559824685f135976c20`。此SHA随本覆盖文件纳入最终包，继续绑定全部原始引用；它不计作完整通过。v2以独立隐藏进程和新编号从头运行Windows验证，未承接v1为新执行成功，原数据和文件未覆盖。
