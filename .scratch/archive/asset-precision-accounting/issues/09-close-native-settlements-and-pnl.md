# 09：贯通资金结算及成本、PnL 的精度合同

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [07：让第三 Asset 费用与返佣形成原币闭环](07-account-for-third-asset-fees.md)、[08：精确接入原币余额与保证金观察](08-preserve-native-balances-and-margin.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S3

## Question

如何通过既有公开 interface 完成“贯通资金结算及成本、PnL 的精度合同”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

在新资产单位下既有资金流、资金费和强制执行的经济事实保持精确，成本释放和 PnL 不重复改变现金。

## Acceptance criteria

- [x] 覆盖已存在的资金流/OpeningBalance/PortfolioTransfer、FundingSettlement、强制执行费用/罚金及真实结算金额，不增加新产品或通用结算平台。
- [x] 所有真实金额依激活单位精确转换；生成金额的 Venue 结算公式/舍入须有明确版本和差分验证，风险估算舍入不能冒充实际费用。
- [x] 保留 AverageCost/OpenCost、部分平仓成本释放余数、完全平仓归零及反向成交合同；费用/返佣/资金费独立分类，RealizedPnL 不产生重复余额变化。
- [x] 能精确表示但不能归属的真实金额才进入 SuspenseAccount 并关联 break；不能表示的金额保持来源未解决，不猜测 Treasury/Suspense 尾差。
- [x] 基础/结算/第三资产与多笔累计边界均有固定整数验收，逐事务逐资产闭合，错误事务不局部提交。
- [x] 既有结算与资产 ledger 恢复同一金额及身份，相关 codec、schema、snapshot/digest 在本票闭合。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、03、04、07、08、09、23、24、25。
- Implementation Decisions：D2、D3、D5、D6、D7。
- 验收矩阵：M05、M06、M09、M12、M13、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。


2026-10-07：07/08已封存（72726cd2/cd5b3f6a），认领09。沿原有 Owner/Core/AccountCoordinator 与实际 Adapter 接缝验证资金费、强制执行及成本释放；缺失的实际结算规范事实接入在既有Adapter中补齐，不新增结算平台或估算实际金额。验收项待执行。

2026-10-07 首个切片证据（未完成整票）：OKX ready REST account bills type8/subType173/174 的已确认资金费 pnl，沿 RawIngress→私有 decoder→实际 VenueAdapter.tryDrain→Owner→既有 FundingSettlement ledger，精确保留来源币种/符号/bill身份。无可归属永续仓位时原币进入既有 Suspense 并锁存 break，Portfolio现金/PnL未被虚构；两笔固定整数总额38606355（USDT scale12），重复无经济作用，日志/快照恢复摘要一致，外发为零。新增完整 canonical payload SHA-256 进入既有 SeenFact；canonical/encoding9、journal29、state33、registry27 同步切换。公开 Owner Debug2/2、ReleaseSafe4/4（含08连续性），私有公开 ingress 定向1/1；修复外层闭合检查漏加 Suspense 的缺口。资金费字段依据 https://www.okx.com/docs-v5/en/，未从费率或USD估值推算实际金额。Owned allocation、成本/PnL、强制执行及完整09验收仍待完成。

2026-10-07 最终离线切片证据：公开 Owner 固定整数成本轨迹覆盖两次建仓、部分释放余数220666666667、反向成本120000000000、完全平仓成本归零；逐步 RealizedPnL 为0/0/9666666667/29000000000/39000000000，费用各1 atom，可信 Core 资金费-4198632165独立分类。后续强制执行实际费用4000000001、罚金2000000003、已实现增量20000000000均只改变现金一次，重复无作用，日志与snapshot恢复一致。

实际 OKX REST资金费公共链追加 unknown Asset、subatom、单笔边界、完整payload身份冲突、原币累计及期初范围检查：+60/-60抵消不能绕过100 USDT gross累计上限；REST25→WS100→OpeningBalance100后，已包含于WS余额时点的bill不再记账，缺失或不晚于真实opening来源边界的bill保持未解决并持久失败关闭。OpeningBalance锁定最新结算Asset余额来源UTC；两个UTC字段均进入snapshot/canonical/semantic digest。即使当前存在组合仓位，外部bill没有结算时点归属证据也只进入既有Suspense并关联break，不推断当前组合应收/应付。

验证：09及既有funding/重复/codec/四shard/五条固定轨迹联合Debug13/13、ReleaseSafe13/13；economics Debug14/14、ReleaseSafe14/14；私有公开ready ingress1/1。Debug/ReleaseSafe实际离线fixture各五条轨迹闭合并重放一致；四shard既有三种恢复路径一致，实际共同摘要3beddffb6cd1c61daea2d1aa3f05e0226582bdfa4e91fe4a2f0ab246a88f64f2，依据两种构建实际结果刷新golden，不沿用旧schema摘要。格式与diff检查通过。Sol6.1 medium Standards/Spec 两轴审核发现并修复历史归属、真实opening来源边界和semantic digest遗漏后，最终源码复查无剩余重大问题。

范围说明：原币第三Asset与base/quote固定整数边界复用已闭合05–08的相同ledger和public验收；本票不生成已确认资金费，不将费率、mark、USD估值或风险舍入当实际结算公式，因此新Venue生成/舍入差分条款无新增适用路径。AverageCost检查证明成本合同，不宣称它证明Venue结算公式。外部资金费结算时点组合分配仍无证明，保持Suspense；离线闭合不构成新在线或生产资格。09完整tracker封存待相关回归最终完成。
2026-10-07 封存：账户协调器及其依赖回归ReleaseSafe97/97；最终联合Debug/ReleaseSafe各13/13。六项本票离线验收闭合，09 resolved；外部资金费归属无证明仍留Suspense，不宣称在线资格。Frontier推进10。

2026-10-07 恢复预查补充修复：11只读预查发现 okx_private_recovery.privateFact 漏列 funding_settlement，既有 CommittedInputs.applyBatch 会静默忽略实际账单。真实Adapter资金费fixture现经该公共恢复入口提交并检查retained.contains，先RED复现跳过，再补共享白名单GREEN；重复恢复入口无经济作用。定向Debug6/6、ReleaseSafe6/6（与当前10工作树联编），日志/snapshot摘要与no-send仍通过。完整raw中断Sweep矩阵仍由11补充，不将本检查称作原始断点恢复资格。
