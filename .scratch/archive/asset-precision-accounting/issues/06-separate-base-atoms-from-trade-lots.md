# 06：精确记录基础资产费用并分离 atoms 与 lots

Type: task
Status: resolved
Assignee: codex/asset-precision-accounting
Blocked by: [05：贯通高精度结算资产费用与原币账务](05-close-settlement-asset-precision.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S3

## Question

如何通过既有公开 interface 完成“精确记录基础资产费用并分离 atoms 与 lots”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

BTC 等基础资产扣费和返佣按真实资产单位更新余额，成交数量保持订单 lots；净资产的交易步长以下余额完整保留。

## Acceptance criteria

- [x] 九位 BTC 测试配置下 0.000000001 费用精确记为一 atom；旧八位配置失败关闭。
- [x] 基础资产费/返佣独立资产 posting，与真实成交 lots 区分；不得把 fee atoms 或绝对资产余额直接转换为 lots。
- [x] 覆盖非单位 lot/tick、不同资产原子精度、净买入/卖出及小于交易 lot 的残余资产；余额与订单成交数量均精确。
- [x] 保持原 VirtualPortfolio 归属、双层资产数量守恒、AverageCost/OpenCost 既定合同，手续费不被塞入成本或改造成 overfill 依据。
- [x] 同笔重复、冲突与 checked arithmetic 极值通过原始事实→核心→持久→恢复验证；新结构/单位更新相应 schema 和 digest。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：02、03、04、07、08、23、24。
- Implementation Decisions：D3、D6、D7。
- 验收矩阵：M03、M05、M06、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-05：认领 Frontier 06；以已提交 05（f6b0e0f4）为基线，沿原始 Adapter→Owner→TradingShard→DurableStore 公开接缝分离基础资产 atoms 与成交 lots。尚未关闭验收项，不授权在线操作。

2026-10-05：已实现并完成以下离线验证，最终双轴审查及补充回归完成，离线切片已关闭。

- 基础资产余额/counter/posting 使用 i128 native atoms，LedgerPosting 显式携带 AssetIdentity；真实成交 quantity 和 OMS cumulative 仍是 gross lots。费用与返佣独立，不进入 OpenCost，不作为 overfill 数量。
- Policy schema3 显式激活 Decimal lot_size；InstrumentRegistry 保存 quantity_numerator/denominator、tick 及资产配置。原生 Adapter 启动缺已提交配置或 profile 不一致时 InvalidConfig；非 cancel 准入逐 Instrument 验证。
- 九位 BTC 一 atom 费用与返佣、非单位 lot=25e-8/tick=.25、买买卖及残余99/249 atoms，经 raw OKX→Adapter.tryDrain→Owner/applyAdapterBatch 验证；残余不足一 lot、组合卖单总需求过量均拒绝。
- 十八位 BTC 原生余额19999999999999999999 atoms（超过 i64）经独立 account 原文、posting、snapshot/log recovery 精确保留；currentSpotAssetBalance 返回原币，无法精确转为整 lot 时 currentNetExchangePosition 返回 null。
- 八位 BTC 无法表示第九位、极端金额、冲突和累计 traded native range200后第三笔100均持久失败关闭，无部分经济提交。重复 raw 无第二次账务；所有场景 no-send。
- canonical/encoding schema7，journal27，state31，registry25；Coordinator snapshot7/input4；原币库存及 posting资产/lot分子进入 codec、snapshot、CanonicalStateDigest，并检查状态范围。
- Debug 根定向24/24；ReleaseSafe 金额/故障/旧样本/物理恢复定向22/22。economics Debug/ReleaseSafe13/13，risk各8/8，Coordinator各22/22；RecoveryCutover Debug7/7。完整根套件按 implement 技能留到14最终执行。
- 实际 Debug/ReleaseSafe main --offline-fixture 五轨迹所有闭合与重放通过，同一轨迹 digest 跨构建相同；four-shard最终actual摘要237bf0381901daf73f042da573ae3431e1d26940fa85c6562e37d3c5def2fa8b跨构建相同后更新golden。Windows --windows-chain-test 两构建exit0、OKX离线raw27/spot20000、durable recovery/no-send通过；总体生产资格仍blocked/false。Linux authoritative入口ReleaseSafe离线编译通过。

2026-10-05：双轴 code-review 发现并修复报告先于 Fill 释放卖出库存、未确认减量 native-amend 丢失旧数量、direct Core fill 单笔原币范围遗漏。库存占用由现有 OMS confirmed/pending/terminal 及唯一已应用经济 Fill 证据推导，含 tombstone 未入账成交；缺侧别来源失败关闭。Core economic_fill 复用同一 canonical_fill_evidence，完整 payload/order identity 参与 SHA 和 fingerprint，不另建库存 store。新增三条公开 Core 回归验证单笔拒绝无任何状态变化、入账卖出释放库存、改单确认前后准入；Debug/ReleaseSafe 各4/4（含入口）。Raw OKX 终态报告先行回归从RED转GREEN，既有 eight native base 场景 Debug/ReleaseSafe 各9/9（含入口）。

Standards/Spec 最终复审均无剩余 material findings。最终 Debug/ReleaseSafe 综合定向各27/27。最终同序 happy/duplicate摘要36c6fb7790389bb8aced8fd2d87b59ae3cdd96c3f8835821d4b63c59fce38c40与four-shard摘要均经两个构建独立确认后更新golden；三个拒绝/未知轨迹保持前述跨构建摘要。最终 actual Windows离线链两构建再次exit0、raw27/spot20000/durable recovery/no-send通过；最终Linux ReleaseSafe编译通过。真实观察含dust时必须保留 native atoms，不能精确证明整 lot 的 Gateway position 时继续失败关闭；未授权在线操作。

06 全部验收项已有上述实际离线证据，Status=done；Frontier 推进至07/08。受支持运行范围是已验证的激活资产/lot/tick和有界金额；第三资产、USD估值与原币保证金区分及其后续闭合仍由后续票完成，不授予线上资格。
