# 07：让第三 Asset 费用与返佣形成原币闭环

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [06：精确记录基础资产费用并分离 atoms 与 lots](06-separate-base-atoms-from-trade-lots.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S3

## Question

如何通过既有公开 interface 完成“让第三 Asset 费用与返佣形成原币闭环”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

已配置第三费用资产与 base/quote 使用同一账本，归属精确；未取得有效估值时明确显示不完整，而非零费用。

## Acceptance criteria

- [x] 沿现有有界配置支持第三费用 Asset；不新增 Venue、交易产品、币种特判或第二账本。
- [x] TradingFee/TradingRebate 按费用币种及原订单 VirtualPortfolio 分别记账；Portfolio/Exchange/Treasury/Suspense 逐 Asset 守恒。
- [x] 未知/未激活 Asset、缺币种和尺度冲突失败关闭；仅有明确来源的零费用才能表示为零，不猜测币种。
- [x] 缺少有效 ValuationRoute/价格时金额仍保留原币，估值明确为未估值/PnL 不完整；不隐式换 USDT 或将未知估值写零。
- [x] 重复、冲突、容量和累计边界在同一公开 seam 验证；宽金额、资产 posting 与未估值状态按其权威/派生性质正确恢复，不弱化摘要。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：03、04、05、06、08、09、24。
- Implementation Decisions：D1、D3、D6、D7。
- 验收矩阵：M04、M05、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-05：从已完成 06 的提交 `92c0ede6` 认领本票；仅实施既有公开接缝上的原币费用、返佣及有界资产配置，验收项待实际验证。

2026-10-06 定向证据（尚待最终审查）：原始 OKX ready ingress → tryDrain → Owner → ledger → DurableStore / snapshot / replay，结算/base/第三资产及原币账户联合 Debug/ReleaseSafe 各 26/26；包括第三资产费用/返佣/显式零、超 i64、未知/不可表示、相同身份冲突、累计界限、单订单部分成交耗尽 ledger 容量。固定整数断言 Portfolio/Exchange 原币 posting、Treasury opening ownership、未估值状态及恢复摘要，未执行任何在线写入。后续发送校验及跨 Venue 连续观察审查修复仍待封存，验收项未勾选。

2026-10-07 最终封存：实现提交 72726cd2。Standards 无阻塞文档规则违例，Spec 最终及收紧上限复核均 0 material findings。拟议 AssetDefinition 先校验既有经济状态和有效账户事实，再替换 registry；Quote25b→10b 与第三资产 Treasury10BNB→5BNB 拒绝后保留旧权威及账务，Owner 日志/快照恢复通过。Debug 定向3/3、ReleaseSafe5/5（含完整 OMS→Gateway→Simulated 接缝），拒绝配置后发送尝试为零。联合原币/恢复各35/35，最终健康/撤单/连续性各8/8；模块及既有实际离线 Windows/Linux 编译链证据见此前记录。仅离线切片完成，09–14仍待实施，全套 main 检查在14执行；新在线/生产资格未运行，父Spec和历史账不变。
