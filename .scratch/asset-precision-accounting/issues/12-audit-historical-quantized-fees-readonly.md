# 12：只读审计历史取整差额并保留更正边界

Type: task
Status: open
Assignee:
Blocked by: [10：用独立 Venue 事实核对逐 Asset 经济账](10-reconcile-independent-venue-economics.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S4

## Question

如何通过既有公开 interface 完成“只读审计历史取整差额并保留更正边界”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

审计员可从已有源事实关联旧 Fill/事务，获得真实金额、已记金额及差额，不改写旧账或误授予新资格。

## Acceptance criteria

- [ ] 按有权限的封存数据只读关联 RawIngress、规范 Fill、订单、LedgerTransaction 与精度版本，报告原值/已记值/差额/Asset/来源事务。
- [ ] 保留 -0.004198632165 和既有 -0.00423723852 有损样本的独立真实值与旧 posting；审计结果不借新尺度改解释旧整数。
- [ ] 缺原文、旧格式无法可靠读取或金额来源不确定时明确标记无法核实，不猜算补账、不删除旧证据。
- [ ] 本票为只读审计入口和固定离线样本；真实账户/生产只读范围遵守原授权，不引入在线写入、凭证暴露或第二核心。
- [ ] 更正仅列出需独立授权的追加冲正/更正方案，引用原事务；本票不实施跨 schema 迁移或经济记录覆盖。
- [ ] 旧在线报告保持旧源码资格范围及原失败状态；审计差额本身不授予新版本资格，未执行项目不得写 passed。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、11、18、22、25、26、28。
- Implementation Decisions：D5、D7。
- 验收矩阵：M01、M14、M16。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

尚未实施；验收项均待执行。本票按 2026-10-03 用户确认的拆分发布。

