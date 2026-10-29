# 09：周期恢复、经济承接与激活屏障

Type: task
Status: resolved
Assignee:
Blocked by: [09a 核心周期闭合](09a-cycle-closure-residual.md)、[09b 恢复与激活](09b-cycle-recovery-activation.md)（均已完成）
Parent: [模块地图](../map.md)

## Question

如何在恢复策略状态后追赶权威事实，并保留原周期风险与期限而不错误授予交易权限？

## What to build

贯通核心恢复、策略 checkpoint 与日志尾追赶、经济引用核对、账户对账和 HostActivationBarrier，使用与共同准入相同的占用权威。

## 完成条件

- [x] 在 Entering、Repairing、Holding、Exiting、Reconciling 分别 checkpoint、崩溃、恢复，保持冻结计划、净收益目标、风险锁存与意图身份。
- [x] 原期限包含停机时间；跨机时钟不可信时不虚构剩余预算，已触发退出不能恢复为 Holding。
- [x] 预留成功但策略尚未观察时按原身份承接；不重复预留、消费机会或重发历史意图。
- [x] 对账、迟到 Fill、基础币费用、费用更正、资金费及残余承接后资金与占用一致；Unknown、永续残仓不因恢复完成而消失。
- [x] 周期完成与占用释放须由完整核心事实支持；未承接残余和未解决历史引用不能提前释放。
- [x] schema/配置/模型不兼容、损坏 checkpoint、缺日志尾、旧会话和旧激活身份阻止错误激活，核心既有安全管理仍可履职。
- [x] Keep/Migrate/Rebuild 与 StrategySuccessor 遵守身份和屏障合同，不重置经济事实、期限或锁存。
- [x] 经公共恢复/激活接缝覆盖 I6–I8、S6-C–I/K/L/N–P；策略恢复不自动授权新开仓。

## Answer

2026-10-29：按用户本次确认的 Windows 本机离线范围完成汇总。当前主树 `477fc436` 已合入 08/09b，重新执行 `python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912`，11 个核心场景及既有 checkpoint 场景通过，exit 0；日志 `.scratch/build/10-prerequisite-09.log`、独立退出码 `.exit`。策略/schema/模型及测试参数沿 [08 合同](../08-real-strategy-contract.md) 冻结；测试值不成为部署参数。

| 完成条件（按上文顺序） | 当前证据与范围 |
|---|---|
| 1 五阶段；2 原期限 | [09b 验证](../09b-verification.md)五阶段、停机到期、UTC 不可信拒绝，本次复跑通过；进入退出后不回 Holding。 |
| 3 原预留/机会 | 同记录 S6-D/E，原身份承接及 next IntentSequence，重放禁止输出；本次复跑无第二周期。 |
| 4 经济与 Unknown | [09a 整合](../09a-integration-verification.md)、[残余经济](../09a-owned-residual-economics-verification.md)、[费用](../09a-fee-verification.md)及 09b 的 maker/Unknown 场景；经济测试与恢复链路分列，不声称每个费用场景均经过 Python Host。 |
| 5 闭合与占用 | [09a 验证](../09a-verification.md)及当前 ADR0019 残余证据；未配置默认关闭，Unknown/永续/未承接引用继续占用。 |
| 6 拒绝与安全；7 版本切换 | 09b 的损坏/缺尾/旧身份、独立核心撤单与 Migrate/Rebuild/Successor；本次公共程序通过。 |
| 8 向量与权限 | 09b 逐项 S6 表和上述经济证据共同覆盖；本次所有恢复场景 opening=false。 |

以上八项按此明确的离线范围验收通过；生产 Asset 阈值、真实 Venue 凭证、跨平台、连续运行容量及模式资格仍未取得，不随本票关闭。10 依赖解除，来源 spec 保持原状态。

2026-10-20 用户确认将实现拆为 [09a](09a-cycle-closure-residual.md) → [09b](09b-cycle-recovery-activation.md)，其中 09b 另依赖 08，09a 依赖 05b。本票保留原完成条件，作为汇总验收，不再独立领取；两票均通过且本票各项证据齐全后才能 resolved，10 的外部依赖继续指向本票。残余阈值与策略 schema/模型/参数冻结仍须提供证据，不能用架构确认替代。
