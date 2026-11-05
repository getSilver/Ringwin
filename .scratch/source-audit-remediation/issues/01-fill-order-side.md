# 01 拒绝与 Order 方向冲突的 Fill

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels:
Evidence level: 已复现，F1

## Question

如何保证 Fill 继承 Order 的方向语义，同时保持合法成交、去重与故障锁存合同？

## Problem Statement

同一买单的卖方向 Fill 能通过公共 TradingShard.apply 并入账，仓位由正确基线的 +100 变为 -100。
层间守恒不证明成交与原订单一致，不能只依赖各 Venue decoder 先行拦截。

## Solution

在权威成交准入中拒绝方向冲突；错误事实不改变经济投影，合法事实继续按原数量、价格、费用及归属记账。

## User Stories

1. 作为策略所有者，我希望买单只接受买方向 Fill，以免仓位反向记账。
2. 作为策略所有者，我希望卖单只接受卖方向 Fill，以保持原始交易语义。
3. 作为账户所有者，我希望冲突不改变余额、费用和仓位，以免污染权威账务。
4. 作为运维人员，我希望保留冲突原文和安全故障，以便查证而非静默修正。
5. 作为恢复执行者，我希望恢复验证相同约束，以免重启接受在线已拒绝的状态。
6. 作为适配器维护者，我希望公共核心承担最终检查，以免每家 decoder 重复承担隐含责任。
7. 作为审计者，我希望重复与冲突仍被区分，以维持幂等记账。
8. 作为策略所有者，我希望 report-first 和 fill-first 均正确，以免到达顺序改变经济结果。

## Implementation Decisions

- 在现有 TradingShard 成交准入比较 Fill.side 与已定位的 OMS Order.side，不静默替换输入方向。
- 错误经济副作用原子拒绝；按既有合同记录安全故障和锁存，不能为了摘要不变而回滚必要安全事实。
- 保持 OMS 交易所报告累计与 AppliedOrderFillQuantity 独立，继续以唯一应用量判断 overfill。
- 覆盖现有原生单位与兼容 fixture 路径，核心不增加 Venue 私有分支。
- 核对 replay/restore 一致性；实际涉及输入含义、状态或摘要变化时判断格式身份影响，不自动迁移已有经济状态。

## Testing Decisions

- 最高入口为 TradingShard.apply(CanonicalEvent)，恢复通过现有 snapshot/replay 入口。
- 复用现有 canonical Fill、报告/成交排列及买卖订单 fixture；不只测试私有比较函数。
- 买→买、卖→卖为正例，买→卖、卖→买为反例；检查经济投影、账本和唯一成交量。
- 覆盖同身份重复/冲突、部分成交、两种报告/成交顺序及合法迟到成交。
- 合法在线与恢复轨迹比较 CanonicalStateDigest；错误输入允许生成既有安全事实。

## Acceptance Criteria

- [x] 两种错误方向均在经济应用前拒绝；两种正确方向正常应用。
- [x] 拒绝不改变仓位、余额、费用、经济账本及 AppliedOrderFillQuantity，安全锁存保留。
- [x] 重复不二次入账，冲突继续拒绝，report-first/fill-first 语义不回退。
- [x] 相关产品和单位路径已覆盖，合法快照与重放收敛，不一致恢复失败关闭。
- [x] 本票最小定向回归通过，记录源码身份、实际命令、格式影响和未测项；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行。

## Out of Scope

历史账务重算、策略方向改变、Venue 协议扩展；不能丢弃 Fill.side 后盲用订单方向。

## Further Notes

依 ADR 0013/0014 保留历史及累计量合同；与 04 无必须依赖。来源见[审阅证据](../evidence.md)。
测试 seam 已获用户确认；本票于 2026-11-04 按该 seam 实施。

## Answer

2026-11-04，源码提交 `9306d06e69a5d35773784e6e066bb44a531a1a1f`，基线
`d973030794cc78c0abc5ccd939dcc0ecabf30e98`。仅修改核心及既有正式回归文件。

- `TradingShard.applyCanonicalFill` 在定位 OMS Order、确认 instrument 后比较方向；不同方向返回 `InvalidFill`，沿既有原子候选路径保留经济故障及 recovery-only 锁存，不修改输入。
- `validateSnapshotStateInner` 验证驻留已应用 canonical-accounted Fill 与 OMS Order 的方向一致；不一致返回 `InvalidSnapshotState`。ReplayTradingShard 原本委托同一 apply，重放使用相同准入。
- 新增公共 apply 回归覆盖 buy/sell、report-first/fill-first、原生/兼容结算消费者共 8 个组合，每组合两笔部分成交。错误方向在首笔及已有部分成交后均被拒绝；经济投影 digest（含持仓、余额、费用、账本及成交证据）与唯一应用量不变，安全锁存成立。
- 合法方向完成 +100/-100 入账，唯一成交总量 100；同身份重复不入账，改变方向的同身份事实仍返回 `ConflictingFillIdentity`。合法迟到 Fill 在终态报告之后仍可应用。
- 每组合验证合法快照及完整稳定日志重放的 CanonicalStateDigest 收敛；重新计算摘要的 Order/Fill 方向不一致快照仍被拒绝。既有 USDC 原生金额、SPOT/线性产品测试补方向反例并保留原有正例及恢复断言。

### 定向验证

平台：Windows PowerShell；Zig `0.17.0-dev.315+5b647b792`；优化模式：Debug。

修复前新增方向回归返回成功并生成 fill/fee/risk facts，预期 `InvalidFill` 的断言失败。
仅增加在线检查后，同一回归又证明方向不一致快照被成功恢复（预期 `InvalidSnapshotState`），补恢复检查后通过。
测试夹具的显式 MarginRules.instrument 接线错误在最终定向运行前修正，未改生产 MarginRules 合同。

```text
python tools/zig-entry.py test src/testing/regression/trading_shard_tests.zig -ODebug --stack 536870912 --test-filter "canonical Fill side must match" --test-filter "USDC isolated economics" --test-filter "SPOT and linear instruments" --test-filter "shared canonical adapter facts" --test-filter "legal private fact permutations"
```

结果：退出码 0，6/6（5 项业务测试及共享入口测试）；[完整日志](../../build/source-audit-01-debug.txt)。
`zig fmt --check src/trading/trading_shard.zig src/testing/regression/trading_shard_tests.zig` 与 `git diff --check` 通过。
正式回归仍由 `src/main.zig` 导入，纳入现有 `zig build test` 全量入口；无需新增构建接线。

### 格式及未测边界

本次补足现有 Fill.side 与 Order.side 的一致性约束，没有新增或改变事件字段、持久状态布局、codec、digest 算法或合法输入单位含义，因此不提升格式身份。合法既有状态维持相同摘要；旧错误方向日志或驻留不一致快照不能据此获得兼容承诺，不自动修复历史经济状态。

本票定向通过；模块最终 ReleaseSafe 全量待全部票完成后统一执行。未运行 Debug/ReleaseSafe 全量、Demo/Testnet、真实凭证/订单、Linux 耐久性或容量资格测试；未重新核验已归档历史中的既有错误账务。

规范审查：0 项发现。职责目录、领域术语与既有 ADR 一致，未引入额外抽象或依赖。
规格审查：0 项发现。方向准入、经济原子性、身份语义及恢复约束符合本票；两个审查均只读，未重复执行测试。

本地 tracker 保留原有未跟踪状态；源码提交仅包含本票两个源文件，不代为提交其余规格文档。
