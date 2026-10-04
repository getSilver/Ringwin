# 03：让有界 Decimal 等价文本贯通规范事实

Type: task
Status: done
Assignee: codex/asset-precision-accounting
Blocked by: [02：停止真实金额取整并持久关闭新增风险](02-fail-close-inexact-economic-facts.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S2

## Question

如何通过既有公开 interface 完成“让有界 Decimal 等价文本贯通规范事实”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

受支持输入长度内的长尾零、符号及全零形式产生同一数值和业务身份；真正越界仍经数值故障路径关闭交易。

## Acceptance criteria

- [x] 明确十进制语法、输入长度、i128 系数、有界 scale 及缩放范围；格式验证之后、系数累积之前裁掉无意义小数尾零，不使用浮点或 BigInt。
- [x] 1 加长小数尾零、正负零和合法前导零的等价表示不会产生假溢出；同一经济事实身份与有效内容一致，RawIngress 仍保留原文。
- [x] 正负整数边界、费用绝对值不可表达、scale 超限、缩放幂及真实系数越界返回可区分失败；格式错与缺值不被规范化为零。
- [x] 通用数值解析复用一个最小算法，覆盖三家 Adapter 使用的 Decimal；不引入 Venue 专用核心解析分支。
- [x] Decimal.parse/exactAtoms 检查与原始 WS/REST→核心→重放样本同时验证；等价文本不削弱冲突检查与完整审计摘要。
- [x] 身份或持久数值语义变化提升 schema；原失败保护持续生效。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：13、14、15、09。
- Implementation Decisions：D4。
- 验收矩阵：M08、M09、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-04 离线切片完成。共享 Decimal 接受可选正负号、至多一个小数点和至少一位十进制数字，拒绝指数、空白和空值；长度上限 1024 字节，规范 scale 与目标原子 scale 上限均为 38。先验证完整语法、裁小数尾零，再 checked 正/负累积，支持完整 i128 最小值。格式、长度、scale、重缩放范围、系数及乘法溢出分别保留错误；绝对值使用 checked subtraction。

Binance/Bybit 的报告身份使用规范 Decimal，完整解析后通过既有 canonical codec 比较 payload 摘要；跨 WS/REST 等价数量、价格、费用及负零 PnL 不制造第二个成交，真实费用变化仍返回 ConflictingFact。两家公开 VenueAdapter partial-fill 合同另验证长尾零报告去重；溢出帧只输出规范 economic_fault，候选帧状态不会提前发布。故障经同一 Owner/Core/Store 写入，重复应用无第二次作用，经济投影不变，OMS recovery_only 在日志与快照恢复后仍存在；本地 private_failed 保持新增风险关闭，排空输出和新私有会话不能解锁。

OKX 原有公开验收加入等价 WS 原文，经过 Owner、DurableStore 和完整 raw replay 后既有成交数量、费用和 CanonicalStateDigest 不变；raw visitor 明确找到普通及长尾零两种原文。同一恢复 fixture 的中断分支使用独立 Store 副本，避免两个 Owner 通过旧 journal 游标并发写同一日志；恢复 Owner 的过程准入 fence 保持生效。真实系数越界、最小 i128 费用重缩放、最小原子金额绝对值、scale 39 和长度 1025 的原始输入均失败关闭并恢复故障。REST 解析边界样本经同一公开故障路径验证；完整 REST 对账期间的正常候选事实仍按既有合同缓冲，不以单页未完成对账宣称完成恢复。

最终定向检查：`zig test src/main.zig -O{Debug|ReleaseSafe} --stack 67108864 --test-filter 'private partial fills' --test-filter 'separates report' --test-filter 'separates deduplicated' --test-filter 'OKX raw private fills' --test-filter 'OKX ready economic faults' --test-filter 'bounded decimal' --test-filter 'production contract'`，两种模式均 9/9 通过。此前组合 canonical/codec/schema/旧故障检查 ReleaseSafe 35/35，两家 private reconciliation 全模块 Debug 各 10/10；zig fmt 与 git diff --check 通过。canonical/encoding=4，journal/state/registry=24/28/22。全仓最终检查、04–14 验收及新版本在线资格均尚未完成；本票关闭不授予生产或 Demo/Testnet 资格。

以下保留实施过程证据，以本段最终结果为准。

2026-10-04 实施中，尚不关闭本票。先通过公开 Decimal.parse 复现长尾零文本假溢出；共享 canonical Decimal 先验证完整语法，再裁小数尾零，checked 正/负累积支持 i128 边界。OKX 重复 Decimal 已替换为同一类型，三家共用长度 1024 字节、规范 scale 38 的有界合同，缩放范围与乘法溢出独立返回错误。Binance/Bybit 费用绝对值改用 checked subtraction，OKX 同类溢出归入规范 overflow，避免新支持的 minInt 导致 trap。公开数值 Debug 3/3 通过；canonical/encoding 升至 4，journal/state/registry 升至 24/28/22。跨 WS/REST 等价事实身份、规范内容冲突、完整 replay 与新范围故障验收仍待完成。


- 共享 parser、schema/codec 与原有 OKX 故障合同的组合 ReleaseSafe 检查：`zig test src/main.zig -OReleaseSafe --stack 67108864 --test-filter 'canonical' --test-filter 'production contract' --test-filter 'OKX ready'` 31/31 通过。该检查不替代三家等价 WS/REST 身份、内容冲突及全矩阵验收；这些仍在本票范围内。
