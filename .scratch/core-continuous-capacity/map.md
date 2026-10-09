# 核心持续运行容量闭合

Status: active

## Destination

在现有 TradingShard、OMS、ExecutionGateway 和 DurableStore 上闭合持续运行：
每分片支持 1,024 个同时存活订单，历史累计事实不因固定内存数组而耗尽；
在明确磁盘和保留合同内持续归档、去重、对账并恢复相同 AuthoritativeTradingState。

## Definition of done

- 业务负载为三个策略类别、4 家交易所接入容量及约 500 个观察组合，仅子集参与做市；不在本波实现策略或第四家 Venue 协议。

- 1,024 是每分片同时存活订单目标，不是包括待归档终态在内的总槽位，也不是每秒速率。
- 四分片验证各自 1,024 个存活订单，共享账户风险上限仍独立生效。
- 当前状态、待归档终态、近期证据、历史身份和磁盘数据有分别冻结的容量与保留合同。
- 所有累计容量闭合，不把瓶颈从 Trace 转移至 OMS、Gateway、经济投影、控制事实或 manifest。
- 历史重复无副作用，冲突失败关闭，Unknown 不自动重发，归档不会丢失唯一成交累计和经济证据。
- 多轮检查点、归档与崩溃恢复通过公共业务接口验收，形成可复现证据。
- 离线容量验收不授予 Windows/Linux 目标平台、Venue 在线或生产资格。

## Rules

- 2026-10-08 的计划阶段已由用户 implement 请求推进为本地实施；在独立工作树逐张完成 Frontier、验证、审查与提交。
- 后续实现一次只执行一张无未完成 blocker 的 Frontier。
- 复用现有 seam；交易所私有事实翻译属于 VenueAdapter，核心不执行网络或磁盘 I/O。
- 不使用静默覆盖、清空幂等历史、重置全局序号或自动重发解决容量问题。
- 持久化历史不是无限存储承诺；保留、磁盘配额、归档滞后和恢复时限必须明确。
- 先明确 ADR 0009 的摘要/Trace 合同演进；不能静默弱化 CanonicalStateDigest。
- 不同步 GitHub，不把历史 closed 地图当作新容量能力证明。
- 本地图不授权部署、Demo/Testnet 写入、生产交易或远程故障操作。

## Route

1. [冻结业务负载、容量和保留合同](issues/01-freeze-capacity-and-retention-contract.md) — blocked by 无
2. [分离权威屏障与内存 Trace 下标](issues/02-separate-authoritative-barrier-from-trace.md) — blocked by 01
3. [贯通检查点、日志轮转与崩溃恢复](issues/03-close-checkpoint-and-journal-rotation.md) — blocked by 02
4. [贯通多交易对观察与选择性交易](issues/04-support-observation-and-selective-trading.md) — blocked by 03
5. [贯通终态订单与发送证据归档](issues/05-close-order-and-dispatch-archive.md) — blocked by 03
6. [贯通成交与费用历史归档](issues/06-close-fill-and-fee-archive.md) — blocked by 05
7. [贯通资金费、账本与对账历史归档](issues/07-close-funding-ledger-and-reconciliation-history.md) — blocked by 06
8. [贯通控制与账户协调历史回收](issues/08-reclaim-control-and-account-coordination-history.md) — blocked by 03
9. [贯通千单负载与安全背压](issues/09-qualify-live-order-capacity-and-backpressure.md) — blocked by 04, 07, 08
10. [验证 Windows 文件持久化与持续恢复](issues/10-verify-windows-file-recovery.md) — blocked by 09
11. [验证 Linux 文件持久化与持续恢复](issues/11-verify-linux-file-recovery.md) — blocked by 09
12. [封存容量闭合证据并交接生产资格](issues/12-seal-capacity-closure-evidence.md) — blocked by 10, 11

依赖主干：01 → 02 → 03；03 后分为 04、05 → 06 → 07、08 三支；04/07/08 → 09；09 → 10 与 11；10/11 → 12。
01已完成合同冻结；02–12尚未实现或验收，只有 blocker 全部完成的票可执行。

## Frontier

- [02 分离权威屏障与内存 Trace 下标](issues/02-separate-authoritative-barrier-from-trace.md)

## Decisions so far

- 2026-10-09：01合同、容量矩阵和双轴审查完成，见 [01证据](01-evidence.md)。速率、冷热分布、保留和资源为合成验收假设；未取得任何容量或平台资格。02为下一张Frontier。

- 2026-10-08：用户确认 12 张纵向任务及阻塞关系，替换未实施的旧五票拆分。01 为唯一初始 Frontier；10/11 互不阻塞，12 仅为整波封存。

- 2026-10-08：Windows 与 Linux 均可独立取得生产资格，见 [ADR 0010](../../docs/adr/0010-qualify-windows-and-linux-independently.md)。
  本波容量合同平台无关；两个平台各自验证持久化、安全、性能和恢复，不以 Linux 通过作为 Windows 的前提。

- 2026-10-08：用户确认先完成计划与本地拆分，按每分片 1,024 个同时存活订单设计。
- 当前源码基线 HEAD 为 9f47ae6f，工作区含既有修改；实施与证据封存时重新记录完整源码身份。
- 当前观察到 OMS 8 个热槽位/2 个墓碑、Trace 256 条、经济事实 32 条/账本事务 64 条，
  DurableStore segment 192 KiB/snapshot 64 KiB/manifest 32 项；这些是源码现状而非目标配置。
- 既有终态墓碑实现只证明有界归档和耗尽时 RecoveryOnly；本波补齐持续回收与历史证据链。
- 覆盖约 500 个 Venue × 产品 × 交易对组合的观察容量与选择性交易；4 家 Venue 容量不代表 4 家协议均已接通。具体做市数量和档位在票 01 作为负载参数冻结。

## Downstream closure

核心容量闭合后分为 Windows 与 Linux 两条独立资格路径；可复用业务核心，不共享平台资格结论。

Windows 路径须先拆分生产合同/准入与报告、常驻业务进程、文件恢复与凭证安全、Web 发布与遥测、
真实 NodeFence 及目标机资格任务；复用 Windows 验证链，但不能将其既有 Demo 报告改称生产证据。
Windows OS 版本、硬件、文件系统和权限基线待专项合同冻结，当前生产资格为未取得。
本波 [10 Windows 文件恢复](issues/10-verify-windows-file-recovery.md)通过后即可推进 Windows 专项，不等待 Linux 或整波封存。

Linux 路径沿用 [Linux 生产资格地图](../production-readiness/map.md)，不重复建生产任务：

1. 本波 [11 Linux 文件恢复](issues/11-verify-linux-file-recovery.md)通过后即可推进，不等待 Windows 或整波封存；收口 [Linux 进程链](../production-readiness/issues/02-run-linux-production-process-chain.md)、
   [事务持久化恢复](../production-readiness/issues/03-persist-and-recover-authoritative-state.md)和
   [凭证准入](../production-readiness/issues/04-unlock-credential-and-pass-security-admission.md)。
2. 按现有依赖完成 OKX/Binance/Bybit 在线链、[Web 操作发布](../production-readiness/issues/08-operate-and-deploy-signed-release.md)
   与[遥测](../production-readiness/issues/09-publish-telemetry-and-build-qualification-report.md)。
3. 完成[真实主备隔离](../production-readiness/issues/10-fail-over-with-lease-and-node-fence.md)和
   [生产资格](../production-readiness/issues/11-qualify-linux-production-and-canary.md)。
   独立 NodeFence 选型、目标设备、账户与资金授权仍由对应票处理。

## Not yet verified

- 合成负载与容量/保留预算已在 [容量合同](capacity-contract.md) 冻结；具体实现及全部测量尚待02–12。
- 当前accepted ADR0009尚未改动；票02在实施前明确修订有序摘要与schema，票03再启用轮转。
- Windows/Linux各自的实际文件、性能、恢复及后续生产资格证据未取得。

## Out of scope

- 提高生产资格、部署或真实下单。
- 无限内存/无限磁盘、通用数据库框架、新控制面、未经测量的低层性能重写。
