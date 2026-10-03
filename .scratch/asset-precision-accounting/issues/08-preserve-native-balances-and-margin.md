# 08：精确接入原币余额与保证金观察

Type: task
Status: open
Assignee:
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

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

