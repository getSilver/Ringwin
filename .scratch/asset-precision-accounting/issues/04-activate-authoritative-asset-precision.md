# 04：贯通 AssetDefinition 激活与精度范围准入

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03：让有界 Decimal 等价文本贯通规范事实](03-normalize-bounded-decimal-ingress.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: done
Phase: S2

## Question

如何通过既有公开 interface 完成“贯通 AssetDefinition 激活与精度范围准入”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

同一份带来源依据的权威资产配置经生效事件到 Adapter、核心及恢复，决定整数单位和可用交易范围。

## Acceptance criteria

- [x] AssetDefinition 明确身份、原子精度、版本、生效屏障、来源证据和允许范围；经现有配置发布与验证生效，不能由 Adapter、链上/提现小数位或 lot 推测。
- [x] 三家 Adapter 及 SimulatedVenue 使用同一激活合同，不再维护互相独立的币种精度常量；未知 Asset、缺版本和未激活配置均停止准入。
- [x] 相同配置幂等，同版本不同内容/版本倒退失败关闭；同一账本历史拒绝在线改变原子精度或重缩放旧余额。
- [x] 配置与金额解释持久化并可恢复；新进程默认设置不改变历史单位；单位和能力尚不能被当前经济路径安全消费时维持 RecoveryOnly。
- [x] 准入证明单笔、余额、累计、乘法中间值、原子重缩放和容量限制；运行时 checked arithmetic 继续存在。
- [x] 十二位 USDT/九位 BTC 仅为测试配置；正式精度逐 Asset 提交 Venue 经济字段来源及范围证据，不能默认这些测试尺度就是生产正确值。
- [x] 配置激活、拒绝和恢复均经 TradingShard 公共 interface、codec、日志及快照验证；当前版本基线刷新后协调提升 schema。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：10、11、12、14、22。
- Implementation Decisions：D3、D7。
- 验收矩阵：M07、M09。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-05：本票实施及定向离线验收完成，Standards/Spec 两轴最终源码复核均无剩余发现；关闭配置激活与范围准入切片，下一前沿为 05。

- 权威配置通过 `CorePayload.asset_definition_activated → Owner.apply → TradingShard.apply → DurableStore` 激活；定义包含 Asset、固定原子尺度、版本、来源 identity/digest/kind、单笔/余额/累计与乘法、重缩放和 posting 容量上限。Core 指定并持久化激活 barrier，同版本相同内容幂等，内容冲突、回退和在线改尺度都登记持久拒绝。
- 有界 Registry 允许 8 个 Asset；posting 容量要求 2–4，覆盖当前事务需要的双 posting 并绑定现有经济模块上限。系数、中间乘法及累计重缩放经 checked i128 验证；OMS 准入及 Core Fill/强制执行共用数量/价格上限检查。真实金额范围在 Adapter 转换及 Core 单笔、余额和累计路径再次检查，包括 Treasury/Suspense 余额及 spot/swap open cost。
- 三家真实 Adapter 的独立 USDT/BTC 尺度常量已删除；所有 Adapter、私有 decoder 与 SimulatedVenue 从同一 Core 激活快照获得金额单位，重连保持该快照。缺配置/未知 Asset/越界金额保留 raw 证据、关闭新增风险并走已有持久故障路径。
- 阶段 schema 为 canonical/encoding **5**、journal **25**、state **29**、registry **23**；快照、稳定 Core codec、审计/语义摘要均纳入定义、来源及允许范围。旧 schema 继续失败关闭。
- 新尺度与真实 Venue 来源配置仍为 RecoveryOnly；旧 micros/i64 和 tick/lot 消费者尚未被后续票迁移。本票仅显式允许测试来源的旧 6/8 配置作为离线兼容范围，不提供任何生产 USDT/BTC 精度默认值。有效升级后的新 barrier 永久使旧风险决定的非撤单 outbox proof 失效；撤单与恢复入口继续保留。
- 十二位 USDT 与九位 BTC 的 raw private fill 测试，经各 Adapter `ingestPrivate/WS → VenueAdapter.tryDrain` 验证固定期望 **4198632165 USDT atoms**、**1 BTC atom**，新增风险发送被拒绝且 transport calls 为零；这不表示旧经济模块已能记账这些尺度。
- 最终当前源码定向组合：Debug **12/12**、ReleaseSafe **12/12**，覆盖配置激活/幂等/冲突/回退/范围拒绝、稳定 codec/日志及快照恢复、三 Venue 十二/九位 raw 金额、缺激活、Simulated 公共合同、已接受 outbox proof 失效与数量/价格边界。公开 Owner 资金结算回归证明：单笔/余额上限 100、累计上限 1000 时首笔 −100 接受，第二笔因 Suspense 余额越界拒绝；原 Owner 关闭，经济状态与摘要不变，新 Owner 日志恢复及快照保持该结果。既有 02/03 OKX 故障及 raw Owner 回归 Debug **3/3** 通过。
- 最终实际 Windows 可执行文件在 Debug 与 ReleaseSafe 均完成 `--windows-chain-test`：exit 0、`raw27`、`spot20000`、`durable_recovery=passed`；验证首次启动提交配置快照交接、进程重启及恢复。各次运行使用独立时钟，不以跨运行 digest 相等作为证据。最终 Linux authoritative + curl shim ReleaseSafe `build-obj` 通过；`git diff --check` 与相关 Zig 格式检查通过。完整 main 测试套件留给 14，不以本票定向验收代替最终封存。
- 两轴审查采用 GPT Sol 6.1 medium、只读当前源码。Standards 无剩余发现；Spec 初审发现 quantity/price、posting 容量与 Treasury/Suspense 范围缺口，补齐公共回归后最终复核 **0 remaining findings**。Core 与 Registry 共用兼容谓词，第三资产等尚不兼容配置仍为 RecoveryOnly。
- 当前 schema 基线通过实际 Debug/ReleaseSafe `--offline-fixture` 刷新：五条固定轨迹在两种构建中产生相同 digest，账本闭合及语义重放检查通过；按当前 journal 25/state 29 的实际结果更新既有 fixture expected constants。对应固定轨迹基线测试 Debug **1/1**、ReleaseSafe **1/1** 通过，不沿用旧 schema 的摘要常量。
- 线上、部署、Demo/Testnet/生产订单、清理、历史账更正均 **not_run**；父 Spec 原文与状态保持不变。正式范围需逐 Asset 提供真实 Venue 经济字段来源证据并完成后续单位消费/范围资格，本票没有猜测生产尺度。
