# 01 设计票验证与审查

日期：2026-10-20。源基线 `e5731d6b173c7f4ce3ad1457280fa72d313d3ea0` 加用户既有未提交目录迁移。初始设计提交 `d4a6ff48`；本次提交只包含设计、proposed ADR 和本票 tracker，源码与迁移均未纳入。

Zig：`0.17.0-dev.315+5b647b792`；Windows PowerShell；测试栈 512 MiB，沿用当前 `docs/source-layout.md` 的主回归运行预算。本票无源码变更，不新增测试。

| 命令 | 结果及范围 |
| --- | --- |
| `python tools/zig-entry.py test src/strategy/strategy_host_gateway.zig --test-filter "subscription merge" --stack 536870912` | 2/2 通过（含入口测试）；证明既有单意图订阅与拒绝合同 |
| `python tools/zig-entry.py test src/portfolio/account_coordinator.zig --test-filter "risk leases allocate" --stack 536870912` | 2/2 通过（含入口测试）；证明既有同账户 gross reservation 租约分配，不是跨账户共同提交 |
| `zig test src/main.zig --stack 536870912` | Debug 完整回归 650/650 通过，进程退出码 0；包含现有组回滚、Unknown、Coordinator、Store 文件故障与恢复路径 |
| Markdown 本地链接检查 | 本票 5 个文件中的 22 个相对链接全部存在 |
| `git diff --cached --check`（仅本票文件） | 通过 |

现有离线测试仅用于核对当前支持范围。提案中的双账户共同准入、周期占用与释放、跨账户 crash/restore 尚未实现；对应新增公共向量列在 `authority-design.md` 第 8 节。本轮没有部署或交易。

## Standards

独立 Standards agent 审查初始 HEAD `e5731d6b` 到 `d4a6ff48` 的四个文档，未将用户其他迁移纳入审查。报告：

> 未发现需修正的硬性规范违规。文档使用本地 map/issues，符合 tracker；01 保持 in-progress，Frontier 与 Decisions 同步，未提前解除依赖。ADR0017 明确 proposed，列出备选、代价和确认门槛。方案保留 VenueAdapter 转换、核心权威状态、独立账户 Coordinator Writer、提交后发布、Unknown pin、历史证明及格式升级边界，与相关 ADR 一致。未发现值得报告的 Fowler smell。

## Spec

独立 Spec agent 按票 01 六项完成条件、H2/H3 来源及当前源码核对同一 diff。报告：

> 未发现必须修复项。覆盖当前公共路径限制、唯一所有者、AB/AC 竞争、共享资金、提交及发送失败、Unknown、残余与崩溃恢复。推荐方案区分金额预留与周期占用、账户分区与组合汇总；跨账户资金不能互抵，共享账户额度必须可证明不重叠，未见内部矛盾。源码关于单账户 shard、4 成员 OMS、Owner commit 后发布和 Coordinator 非跨账户提交者的主要声称准确。未扩大实现范围；ADR 保持 proposed，01 保持 in-progress，后续阻塞未解除。容量数量留 05a 冻结符合后续容量合同要求，无需臆定账户数或周期数。

Standards：0 项规范违规 / 0 项 smell；Spec：0 项发现。上述报告记录提案审查时的 proposed/in-progress 状态；用户确认后的状态见下节。

## 架构确认与关闭

用户于 2026-10-20 对方案 A 及 05/09 追加拆分回复“确认”。ADR0017 更新为 accepted，01 完成条件全部勾选并 resolved，四张子票正式发布。05/09 保留为汇总验收，06/07 → 05、10 → 09 的外部依赖不变。

Frontier 更新为 02、04、05a、08；02/04 当前已有 in-progress 认领，本次保留，05a 仅有的设计 blocker 01 已完成。05b 仍等待 04/05a，09a 等待 05b，09b 等待 08/09a。容量数值、全局预算绑定、残余阈值及策略 schema/模型/参数冻结不因架构确认视为通过。

本次确认落盘仅修改 Markdown；检查本地链接、依赖无环、Frontier 与状态一致性及本票 staged diff 空白，不重复运行已通过的完整 Zig 回归。

确认落盘检查结果：14 张票的依赖无环，Frontier 恰为无未完成 blocker 的 02/04/05a/08；模块及 ADR 共 18 个 Markdown 文件的 71 个本地链接有效。01 resolved、ADR0017 accepted、05/09 open，状态与 map 一致。
