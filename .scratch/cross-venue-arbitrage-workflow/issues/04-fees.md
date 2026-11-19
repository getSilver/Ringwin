# 04 手动费率贯穿扫描和开仓复核

Type: task
Status: in-progress
Assignee:
Blocked by: 无
Parent: [模块地图](../map.md)

## Question

人工调整费率后哪些候选和决策受影响？

## What to build

按账户、适用产品和费用币种保存 Maker/Taker 费率版本，供扫描及策略复核。

## 验收条件

- [ ] 百分比到 ppm 精确转换；保存后持续生效，跨时间和重启仅手动修改才产生新版本。
- [ ] 改费后同一正价差由可交易变为不合算；开仓复核识别旧版本，历史按原版本重放。
- [ ] 缺费率提示具体腿；成交按实际费用或返佣原币入账。

## 实现证据（2026-11-19）

已实现原子持久人工费率、精确百分比转换、不可变历史版本、扫描费用覆盖、缺失腿提示、批准及 Admission 注入式版本复核。Web API: GET/POST `/api/manual-fees`。负费率仅保留配置，未确认返佣不改善准入；实际账务沿用 canonical 核心。

针对性验证：test_fee_schedules 3、test_scanner_evaluation 11、test_arbitrage_evaluation 25、test_arbitrage_admission 17、test_scanner_console 12 均通过。未执行全量构建/测试，证据为离线 synthetic fixture。

尚未关闭：正式策略 Host 必须注入 FeeSchedules 并为 Option 绑定对应 fee_version；前端费率表单与真实成交费用/返佣的本票端到端验收尚未完成。费率改变导致校准作用域失配时保持拒绝，需要匹配研究证据，不重写历史校准。
