# 13：闭合多 Venue 精确账务公开接缝合同

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [11：证明精度账务与故障状态的崩溃恢复](11-prove-precision-crash-and-replay-invariants.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S5

## Question

如何通过既有公开 interface 完成“闭合多 Venue 精确账务公开接缝合同”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

OKX、Binance、Bybit 和 SimulatedVenue 经各自真实 Adapter 的公开路径遵守同一精度、费用、故障与恢复合同。

## Acceptance criteria

- [x] 复用共享合同及各 Venue 的原始 WS/REST fixture，经 ingest/tryDrain→Owner→TradingShard→DurableStore→snapshot/replay 验证；不得只测共享 helper 或借 SimulatedVenue 替代真实 Adapter。
- [x] 三家 Adapter 均使用同一激活资产精度，无私有精度常量遗留、Venue 专用核心分支、第二 runner 或通用插件。
- [x] Venue 单笔/累计 fee/rebate、符号和币种按其能力合同翻译；字段语义或粒度无法证明时拒绝，核心不接私有字段。
- [x] 逐 Venue 覆盖精确成功、微费用/返佣、base/quote/第三资产、非单位 lot/tick、未知资产、长尾零和真实溢出。
- [x] 同一共享矩阵覆盖无 pending 故障、队列/存储失败、幂等、冲突、合法排列、独立对账及重启锁存，replay 无发送。
- [x] 每个期望值为独立固定整数/尺度；资产未估值明确不完整，OMS cumulative 和唯一应用 Fill 数量保持分工。
- [x] 矩阵只产生离线证据，不关闭现有在线/生产资格票，不执行账户交易或清理。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、02、03、04、05、06、07、08、09、10、11、12、13、14、15、16、17、18、19、20、21、22、23、24、25、27。
- Implementation Decisions：D1、D2、D3、D4、D5、D6、D7。
- 验收矩阵：M01、M02、M03、M04、M05、M06、M07、M08、M09、M10、M11、M12、M13、M14、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。


2026-10-08：11已提交e2e54f04、12已提交a358def0/1df6bb86，root认领13。复用实际Binance/Bybit/OKX与Simulated公开Adapter接缝及同一Owner，按当前来源字段重新核对，不沿用旧micro单位结果。只做离线矩阵；最终完整main suite及双轴全分支审查待14。

2026-10-08初步切片：新增actual Binance/Bybit private ingest→tryDrain→同一Owner→恢复/snapshot回归，quote12/base9、lot2e-7/tick0.25，单原币微费用1atom、gross base200atoms与cash89989999999999独立整数核对，重复无经济/审计改变，transport calls=0。新集成路径发现两家私有hash identity使用u128而权威经济/OMS界面要求可表达为u64；修复各私有统一identity helper读取SHA前8字节，维持完整payload/digest冲突校验，不在runner或核心做Venue专用降宽。当前不是全多Venue矩阵完成。

官方来源检查：Bybit Execution文档明确execFee/feeCurrency及extraFees（https://bybit-exchange.github.io/docs/v5/websocket/private/execution），非空extraFees未支持时不得静默忽略。公开回归先观察到原路径接受并遗漏额外收费，现统一decodeExecutions拒绝UnsupportedFeeComponents并向Owner提交decoder_rejected经济故障，经济状态不变、RecoveryOnly、原始证据与恢复/snapshot保留；初步Debug3/3通过。Bybit当前wallet-balance文档（https://bybit-exchange.github.io/docs/v5/account/wallet-balance）仅列UNIFIED，availableToWithdraw已deprecated，USD totalAvailableBalance也非原币；当前legacy形状fixture及缺债务/原币可用证明不能当作新账户资格或第三币opening依据。源scope、现代wallet与其余完整矩阵仍待闭合。
2026-10-08完成离线合同切片：实际Binance/Bybit共享矩阵经ingest→tryDrain→Owner→原币ledger→decision journal恢复与snapshot，Debug/ReleaseSafe最终各14/14（report-13-debug.log、report-13-final-releasesafe.log）。覆盖quote/base/third微fee及rebate、zero、长尾零、未知/不精确/真正溢出、无private订单link、解析拒绝、extraFees、现代wallet scope、conflict、decision append/commit失败；恢复transport sends=0。Bybit report-before-Fill与Fill-before-report的SemanticAuthorityDigest相等，CanonicalStateDigest保留各自审计顺序。日志逐场景记录激活registry内容SHA、decision/raw barrier和两种digest；第三币余额及portfolio归属使用独立固定整数，未估值保持incomplete。

复用真实OKX既有native settlement/base/third/funding/fault/store/raw-recovery与独立bill证明；新增实际WS长尾零与REST短文本身份回归。OKX native原31项Debug/ReleaseSafe各31/31，新tail项各1/1；根级联合ReleaseSafe47/47记录在report-13-releasesafe.log。Simulated真实trySend→tryDrain→Owner新增2项（7个case，含split fee/rebate/third、unknown、range、conflict），两模式各2/2；它输入canonical atoms，所以文本Decimal/inexact来源粒度不适用，不代替真实Venue。队列/存储/文件崩溃的共同Owner合同复用11及venue_adapter_contract，而非复制第二套恢复核心。

当前来源边界：Binance仅在recorded /api/v3/account target + accountType=SPOT下证明原币free/locked与Spot无借贷scope，REST updateTime和WS u各自保留；combined scope/bill proof不能由Spot snapshot推出，zero/nonempty/missingtarget/missingrange公开请求均持久未解决、不改账、不解锁，最终定向Debug/ReleaseSafe各2/2。Bybit非空现代UNIFIED wallet精确校验walletBalance/spotBorrow/borrowAmount/locked，但无法证明原币available/productscope，保留raw并持久故障；禁止deprecated availableToWithdraw和USD总可用额变成原币，钱包/decoder定向两模式各7/7。共享fee矩阵的Core opening是明确trusted离线前置，不是账户资格。

数值检查在丢弃未归属client之前；malformed JSON和冲突也走持久canonical fault，保持来源SHA、不伪造Fill归属或reconciliation请求。Binance/Bybit此票证明decision日志恢复及snapshot，不宣称完整真实raw-history恢复资格；OKX共同Owner ingress-sweep/文件恢复证据仍由10/11承载。未新增persistent canonical字段layout，canonical/encoding10、journal30、state34、registry28、acceptance13不变；实际Adapter语义与identity修订只能随当前新源码证据使用，旧资格不继承。

最终全套与独立双轴全分支审阅待14。全部只离线；Demo/Testnet/production资格仍not_run/false，父Spec原文/生命周期不改，没有部署、账户调用、交易、清理或历史更正。