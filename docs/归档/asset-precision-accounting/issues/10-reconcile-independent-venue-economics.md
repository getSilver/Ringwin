# 10：用独立 Venue 事实核对逐 Asset 经济账

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [09：贯通资金结算及成本、PnL 的精度合同](09-close-native-settlements-and-pnl.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S3

## Question

如何通过既有公开 interface 完成“用独立 Venue 事实核对逐 Asset 经济账”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

本地内部镜像一致但偏离真实金额时，独立 snapshot/bill/fill 核对仍能产生持久 ReconciliationBreak。

## Acceptance criteria

- [x] 按匹配的账户/Asset、产品、时点、来源范围和游标核对独立 snapshot/bill/fill；不拿不同时间范围硬比金额。
- [x] 构造 Portfolio/Exchange 两层相同但与 Venue 不同的金额，必须发现差异、记录稳定 break 并关闭新增风险。
- [x] 匹配真实独立事实时逐 Asset 精确闭合；禁止宽松容差、覆盖余额、虚构划转或用新原子精度掩盖差额。
- [x] WS/REST 费用粒度、source identity、重复补证和迟到事实保留权威语义；无法可靠证明粒度/身份时失败关闭。
- [x] 未解决数值失败、未应用 Fill 和 Unknown 不允许被一次成功对账/重连顺带清除；恢复权限继续遵守人工授权。
- [x] 固定精确值、差异、缺范围、冲突及重复沿公共接口及持久恢复验证，不用被测函数产生 expected。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：08、09、11、15、16、18、25。
- Implementation Decisions：D5、D6、D7。
- 验收矩阵：M07、M10、M12、M13、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

实施中，最终验收项仍待恢复补证和审查封存。本票按 2026-10-03 用户确认的拆分发布。


2026-10-07：09已封存71b72ecc，认领10。账户投影与经济账分离，独立对账按真实来源时点、范围及经济游标匹配，不以bootstrap收齐或两轮稳定代替经济完整性；缺证明保持失败关闭。验收项待实施。

2026-10-08：Sol6.1 medium实施代理额度耗尽，root接手，不缩小10范围。已补实际HTTP target范围/分页证据、独立before/after原币cashBal与账单bal/balChg链、已应用Fill完整摘要和逐Asset精确对比；经济活动非空时也能发现独立费用差异。Root补较旧REST不覆盖较新可用/负债/保证金观察、未解决结果完整身份及重复、无经济证明的transport complete不授予恢复权限。Source schema canonical/encoding10、journal30、state34、registry28当前工作树同步；验收仍待最终覆盖/审查封存。

2026-10-08：联合 Debug 定向 17/17 通过，含真实第三资产微费用、原币现金差异、未应用 Fill、旧 REST 可用/负债观察及资金费故障；满容量 canonical 经济证明 codec Debug 1/1 通过，宽 i128、八资产、四 query、十六 fact 及旧 schema/截断拒绝保持完整。两轴复核共同发现 RawIngress 尚不能恢复查询文本与完整对账请求范围，已交 Sol6.1 medium 代理修复；Owner 决策日志恢复不替代 Raw sweep。当前仅支持 cash proof，最多十六账单、四 query，非零 posBal/posBalChg 保持未解决，不宣称 isolated-position 资金费区间证明或任意历史范围。分页补证仍执行中。

2026-10-08：满容量经济证明及资金费 codec ReleaseSafe 2/2、economics ReleaseSafe 14/14 通过；git diff --check 通过。上述结果只覆盖本地定向合同，Raw sweep 缺口和联合最终检查仍未封存。

2026-10-08：实际 Debug/ReleaseSafe native-10 二进制均完成 offline-fixture 五条轨迹，ledger=closed、各自重放等价且两构建摘要一致：happy/duplicate d61cb6490ad41e43e86c296951d4276711d788b47a2e4b9007b478622cc2cc37，market-gap 983f1bb314388444679f3fc409e2a7aff1eabf0c73ac19042ec04dc9c7da109f，risk-rejection 0b95b1b352303da39b88c83c3a03651e448df12f644bdfe70ab3af182e7da783，unknown 5df38b3319432c168be482c67fa11dd63fa359095f65abdbbb0c45b7a550d831。四分片三条恢复路径在旧 golden 断言之前已互相核对一致；两构建实测共同摘要9e949aa1c2826aa00a5b4987267b426f1f5b6de10ad3c537c04b1d722739e190。依据实测更新原 fixture 基线，更新后定向检查仍执行中，原二进制 FourShardEvidenceDrift 不记作通过。

2026-10-08：基线更新后 four-shard/schema Debug 3/3 及 four-shard/固定五轨迹/schema ReleaseSafe 4/4 通过。恢复代理的初步 raw proof Debug 2/2 通过并补 exact canonical digest、结果完整摘要与重复 sweep；root继续追踪发现 Windows ExecutionOwners.replayPrivateFrame 有独立旧 REST 路由，新增 request/query 元数据尚需贯通该实际进程接缝，已交同一代理修复。不能只以 recovery.Sweep 单一路径宣称全部恢复已关闭。

2026-10-08：共享 DecoderReplay 后现有文件重开/部分提交/固定轨迹/schema Debug 5/5 通过；当前实际 Debug 二进制 four-shard acceptance 全入口通过（schema13/journal30/state34，3 recovery paths、replay无发送）。实际 --windows-chain-test generation2终止为 ConflictingCanonicalIdentity；完整raw从1重建之后继续新事件未衔接原非raw/synthetic canonical cursor。已交实现代理根因修复，进程链失败状态保留，本票不关闭。

2026-10-08最终验收：当前完整切片联合定向 Debug24/24、ReleaseSafe24/24通过。覆盖独立固定原币值、内部镜像一致但Venue差一atom、非空真实Fill/微费用/第三Asset费用、未应用Fill、未知/错误版本/冲突、较旧REST可用与负债观察、无范围、满八行页+精确after+空终止页及缺尾页。Native codec保留八Asset/四query/十六fact与超i64有符号金额，旧schema及截断拒绝。Source精度与seen完整摘要在canonical/encoding10、journal30、state34、registry28下闭合。

恢复：实际RawIngress持久完整经济请求（metadata v1）和原HTTP target，既有Owner Sweep与Windows ExecutionOwners共用DecoderReplay，不重构/猜造查询。真实文件存储的pending proof、已提交proof重复sweep、空区间请求及缺closing/dangling query覆盖；同一raw事实序列核对完整CanonicalStateDigest、SemanticAuthorityDigest、结果payload完整SHA/identity、账本、raw barrier、零发送。Windows full-history decoder从1重建，返回live前经既有resumeAfter抬至committed floor且不可回退；新故障保留原始evidence并先持久提交。原ConflictingCanonicalIdentity实际进程失败修复后，两构建--windows-chain-test终止exit0、windows_okx_offline=passed、role_ownership/durable_recovery=passed、replay_send_capability=false；其故障注入子进程预期拒绝不算未处理断言。

权限与经济边界：成功对账不写任何余额/posting，不覆盖本地账；匹配的独立cash proof核对每个Asset及已应用唯一经济fact、gross费用/返佣，差异形成稳定break；无法证明的范围/粒度/身份保持未解决，已有numeric fault与Unknown不清除。未获实际组合归属的资金费仍Suspense；非零posBal/posBalChg和超16账单/4query范围不宣称证明。全局Windows资格报告保留blocked/offline=blocked/read_only=not_run/demo_live=not_run/production_qualification=false；Debug/ReleaseSafe进程各自使用其实际时钟生成不同运行事实，不能跨运行硬比过程digest。完整main suite和最终封存待14；不新增在线权限。

审查：Sol6.1 medium独立Standards与Spec两轴复核最新共享replay与live handoff，无剩余重大问题；实际进程复验关闭审查保留项。格式与diff检查通过。Linux authoritative ReleaseSafe编译终止exit0通过（x86_64-linux-gnu）；仅编译，不构成Linux运行/部署资格。