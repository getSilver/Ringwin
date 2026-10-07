# 08：精确接入原币余额与保证金观察

Type: task
Status: in_progress
Assignee: native_margin_08_prep
Blocked by: [06：精确记录基础资产费用并分离 atoms 与 lots](06-separate-base-atoms-from-trade-lots.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S3

## Question

如何通过既有公开 interface 完成“精确接入原币余额与保证金观察”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

bootstrap 和连续账户观察保留原币总额、可用、占用及负债；真实保证金与 USD 估值分开，不因保守风险计算改写来源。

## Acceptance criteria

- [ ] 账户快照/增量的原币 total/available/held、cash、各负债及原币保证金按已激活资产精度精确接入，不分别 floor/ceil。
- [ ] USD 等估值与 USDT 原币账户金额区分；相同小数位不证明同一资产或等值，不能借虚构换币满足 margin 字段。
- [ ] 真实观察与内部风险预留分别表达；在现有风险合同下缺必需原币事实或单位不明时禁止新增风险。
- [ ] 来源会话、bootstrap 身份、范围、时点、游标和序号校验继续生效；观察不是覆盖本地经济账的命令。
- [ ] 精确/不可表达、未知资产、重复冲突及核心窄化样本经公开接缝验证；错误不让旧账户视图保持健康。
- [ ] 资产配置与观察解释进入相应 codec、快照和恢复，必要的 schema 变化随本票完成；不搭建通用估值平台。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：04、10、11、12、15、16、23、25。
- Implementation Decisions：D2、D3、D5、D6、D7。
- 验收矩阵：M05、M06、M07、M09、M10、M15。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-06：正在实施；与 07 共享 canonical 8 / encoding 8 / journal 28 / state 32 / registry 26 切换。原币 AccountMargin 与 USD 来源 Decimal 分开；OKX position 的实际 margin/upl 必须携带 ccy 并匹配已激活 Instrument 结算资产。AccountProjection 校验 key/单位、bootstrap 内容冲突与来源序号，实际金额进入 canonical/semantic digest，拒绝的观察不推进已应用游标。

模块公开检查：AccountProjection 与 canonical codec Debug/ReleaseSafe 各 11/11，Binance 私有 ingress/drain 各 6/6，Bybit 各 5/5；OKX Adapter/private Debug/ReleaseSafe 定向各 19/19。Windows 检查使用 `--stack 134217728` 容纳既有有界批次的 Debug 栈副本。尚待根代理 Owner/DurableStore/snapshot/replay、运行时和最终两轴审查；验收项保持未勾选，不构成在线资格。

来源单位依据：[Binance Account Information](https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/account) 明确 aggregate 在 single-asset 为 USDT、multi-assets 为 USD；缺账户模式不猜单位。[Bybit Wallet Balance](https://bybit-exchange.github.io/docs/v5/account/wallet-balance) 明确账户汇总为 USD，缺失原币 available 不从 walletBalance 补猜。

2026-10-06 审查修正：公开 `ingest/drain → AccountProjection.apply` 先复现 Bybit 首个 ready 钱包观察 `SourceSequenceGap`，随后修复 Binance/Bybit bootstrap 与连续余额/仓位/保证金观察共用逻辑账户流、每个观察独立 checked 序号；Envelope 保留实际 WS/REST 来源及帧序号。Binance 回归覆盖 bootstrap 前缓冲、REST 屏障、同帧三项账户观察、重复与显式缺口；Bybit 同帧 balance/margin 顺序与重复/缺口通过。Binance Debug/ReleaseSafe 各 7/7、Bybit 各 5/5；OKX 移除未使用 marginFor Registry 参数后的定向检查 1/1。最终 Owner/运行时及审查仍由根代理取证。

2026-10-06 根代理定向证据（尚待最终审查）：原始 OKX quote scale12/base scale9 的 cash/total/available/held/各负债及高精度 USD valuation，经 Owner 与日志/快照恢复保持固定整数和来源 Decimal；缺 cash、全 held、债务及 USD margin 非零时禁止新风险且不覆盖经济账。审查发现 accepted outbox 在后续缺 cash 时仍可能发送，已在 qualification / Gateway 共用 currentNativeRiskCash；公开健康控制可发送，降级账户后独立 Gateway NotSent、send_attempt_count=0、传输尝试无增长，Debug 回归 2/2。当前仍等待 Binance/Bybit 实际 Adapter→Owner 连续观察恢复证明及最终复核，不关闭票。

2026-10-06 完整公开连续性证据：新增 native_account_continuity_acceptance 经实际 Binance/Bybit Adapter 的 REST bootstrap 和 ready WS 多行余额/保证金/仓位 → tryDrain → Owner.applyAdapterBatch，固定整数、整批重复、旧 bootstrap 重复、较早及最新观察同身份冲突、逻辑序号缺口均经过日志恢复/快照摘要校验；无传输发送。Core 复用 AccountProjection 有界已见观察处理语义重复，冲突持久失效。联合原币/故障/连续性/固定轨迹/四 shard Debug/ReleaseSafe 各35/35；最终健康视图及安全撤单/恢复定向各8/8。IntegritySnapshot.account_valid 排除未解决经济故障，currentNativeRiskCash 同样关闭；最后有效观察保留供受限撤单，不被当作当前风险准入证明。最终两轴复核仍进行中，未关闭票。
