# 02 Binance 与 Bybit Amend 遵守授权和金额限额

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: ready-for-agent
Evidence level: 两家 adapter 已复现，F2

## Question

如何让可以增加暴露的 Amend 遵守显式写授权及额度，同时保留合法撤单？

## Problem Statement

显式 Testnet 授权和金额检查仅覆盖 place。关闭 explicit_enable、将上限设为 1 后，带合法订单引用的 amend 仍进入 transport。

## Solution

非撤单操作遵守完整的 adapter 授权；改单根据正确的变更后暴露语义校验限额，不能绕过新单保护。

## User Stories

1. 作为账户所有者，我希望关闭显式写授权后不发送改单，以使开关覆盖相关副作用。
2. 作为安全负责人，我希望改单也验证凭证权限与环境，以避免额外授权入口。
3. 作为风控负责人，我希望改单最终暴露受限，以防提高数量或价格绕过上限。
4. 作为风控负责人，我希望批量改单遵守批次限额，以免拆分规避保护。
5. 作为执行人员，我希望保留合法撤单，以便关闭新风险后收敛存量订单。
6. 作为策略所有者，我希望批准范围内的改单继续可用，以免修复变为禁用功能。
7. 作为审计者，我希望拒绝能证明没有发送，以区分 not_sent 与 Unknown。
8. 作为恢复执行者，我希望拒绝不清除既有 Unknown，以免重获不当发送许可。

## Implementation Decisions

- 在两家现有 VenueAdapter implementation 收拢非撤单授权，不新建通用身份或协议框架。
- 显式开关、目标环境、可读/可交易、禁止提现等沿用 TestnetAdmission 合同；缺证据拒绝。
- 按 TargetRemainingQuantity、OrderRevision 和累计成交屏障确定改单数量含义，再计算既有单笔/批次限额，不能将剩余量误当原总量。
- 金额绑定真实资产与批准品种，不合并不同结算资产。
- 撤单保留独立准入，特例不能扩展至 amend；Gateway 来源证明不替代 adapter 显式权限。

## Testing Decisions

- 从 VenueAdapter.trySend/tryDrain 进入，使用无网络 transport 记录副作用。
- 复用现有 explicit admission、bounded notional、cancel 与共享 VenueAdapter 合同测试。
- 将禁用授权与金额超限拆成独立反例，另保留两者同时出现；两家分别覆盖。
- 覆盖单条/批次、限额边界、凭证权限、环境不匹配、部分成交及过期 revision。
- 增加 Gateway 已获一般风险资格、adapter 显式权限仍不足的公共调用反例。

## Acceptance Criteria

- [x] 两家 adapter 禁用显式授权时 amend 均不发送，transport.calls=0。
- [x] 其他必要授权条件逐一失败时均 not_sent；已有 Unknown 不被清除。
- [x] 授权正常时单笔与批次超限分别拒绝，限额内合法命令通过。
- [x] 正确处理改单剩余量与累计量；无法证明最终暴露则失败关闭。
- [x] 撤单正例仍遵守原有条件正常执行。
- [x] 两家最小定向回归通过，记录源码身份、命令及能力限制；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行。

## Out of Scope

扩展原生改单、重做 CancelConfirmCreate、新增权限开关、Testnet 请求或真实凭证。

## Further Notes

与 03 无硬依赖；建议先完成本票以便其复用发送准入回归。来源见[审阅证据](../evidence.md)。
2026-11-04 已实施并通过最小 Debug 定向验证及两轴审查；模块最终 ReleaseSafe 仍 pending。

## Answer

2026-11-04：源码提交 `93c7a9ec2e2daae037ca9261223963ed887bf3d0`，基线 `d9e6bef8e33443ea91fade6978a1ff890d91c6c1`。本票 Debug 定向通过；最终 ReleaseSafe 全量仍 pending。

- 按当前源码确认两家 adapter 的 validate 与 batchWithinNotional 原先只保护 place；先新增公开 trySend/tryDrain 反例，旧码两家均出现 expected not_sent / actual submitted。非撤单现在共用完整显式 TestnetAdmission 与单笔/批次金额检查，撤单继续走原准入。
- 新增 adapter 请求字段 `OrderCommand.amend_expected_cumulative_quantity`，与私有原文经 RawSink 提交并 decode 的既有报告核对：账户、订单、client/venue ref、方向、品种、规则、前一 revision 及累计成交量必须精确匹配。缺证据、过期 revision/累计屏障、缺价格、错引用、来源 gap 或溢出均拒绝，transport 不调用。
- 规范 quantity 仍为 TargetRemainingQuantity。Binance spot cancelReplace 编码替代单剩余量；Binance linear 与 Bybit 编码累计成交量加目标剩余量，使用 checked i128 算术。现有 Testnet 限额保守地约束实际编码的完整订单金额，并对同批非撤单求和；两家仅允许固定 BTCUSDT spot/linear 身份，金额始终为 USDT，不合并其他结算资产。
- 使用原文部分成交 3 lots / 已成交 2 lots / 目标剩余 1 lot，检查真实签名 transport body：Binance spot 为 0.0001；Binance linear/Bybit 为 0.0003。分别覆盖五个权限条件、单独超限、权限与超限同时失败、单笔与批次边界、Unknown 后禁用/恢复授权仍拒绝、撤单正例。
- Gateway 公共 sendFromShard 从真实源拥有的风险资格与 durable dispatch 进入两家 adapter：其他条件相同，仅 explicit_enable=false 时 transport.calls=0，启用时到达注入 transport；该 Gateway 反例使用 place 证明一般风险资格不能替代 adapter 显式权限，Amend 反例及正例通过 adapter 公共 seam 验证。
- 能力限制：两家私有 decoder 当前只输出 revision 1。该报告最多证明一次后继 revision 2 的限价改单；一旦进入 transport 即消费证据，不能靠重复报告或重新开授权继续改单。后续 revision、非 limit amend、缺少真实订单报告或累计屏障的调用失败关闭。未扩展原生改单/CancelConfirmCreate；现有 Gateway OMS 转换仍不提供 venue_order 或累计屏障，其未完成的原生改单路径继续失败关闭，不能宣称 Gateway 原生改单闭环完成。
- 格式影响：新增字段仅在非持久 AdapterRequest 的 OrderCommand 中；canonical.Payload、canonical codec、journal、核心 snapshot、Gateway DispatchProof 布局及 digest 均未改变。新增报告缓存/消费标记是 adapter 私有会话状态，beginSession 重建，不迁移或重写历史经济状态。

平台：Windows x86_64，Zig `0.17.0-dev.315+5b647b792`，默认 Debug，使用仓库验收的 512 MiB 测试栈。命令与实际结果见 [定向验证记录](../../build/source-audit-02-verification.md)：Binance 9/9、Bybit 8/8、Gateway 3/3，退出码均 0（各含一个共享 entry 测试；Binance filter 另覆盖既有 OKX 共享合同）。新增测试所在 adapter 与 Gateway 均由 src/main.zig 导入，进入最终 zig build test。

初始独立测试未设仓库栈预算，在 activatedTestAssets → TradingShard.apply 溢栈；加 --stack 536870912 后验证。fixture ingress 阶段及报告可选 reduce-only 处理问题已在最终成功运行前修正。zig fmt --check、git diff --check 通过。

两轴审查：Standards 0 项文档规范违规；Spec 0 项可确认阻塞问题。两轴均未运行额外测试，确认上述 Gateway 与保守总量限额边界必须保留。未运行全量、ReleaseSafe、Demo/Testnet、真实凭证、在线交易或目标平台耐久/生产资格验证。最终 ReleaseSafe 统一待所有票完成后执行。
