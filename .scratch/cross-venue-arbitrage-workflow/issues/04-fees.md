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

- [x] 百分比到 ppm 精确转换；保存后持续生效，跨时间和重启仅手动修改才产生新版本。
- [ ] 改费后同一正价差由可交易变为不合算；开仓复核识别旧版本，历史按原版本重放。
- [x] 缺费率提示具体腿；成交按实际费用或返佣原币入账。

## 实现证据（2026-11-19）

已实现原子持久人工费率、精确百分比转换、不可变历史版本、扫描费用覆盖、缺失腿提示、批准及 Admission 注入式版本复核。Web API: GET/POST `/api/manual-fees`。负费率仅保留配置，未确认返佣不改善准入；实际账务沿用 canonical 核心。

针对性验证：test_fee_schedules 3、test_scanner_evaluation 11、test_arbitrage_evaluation 25、test_arbitrage_admission 17、test_scanner_console 12 均通过。未执行全量构建/测试，证据为离线 synthetic fixture。

补充证据：

- RingwinUi 正式交易所设置页通过 OwnerSession 保存 Maker/Taker 百分比；离线浏览器验证重启和重新登录后还原原始百分比及版本。等价数值或仅换行顺序不会形成新版本。
- OKX 与 Hyperliquid 公共协议夹具经过原生解码和认证 HTTP。保存高费率后同一正价差转为 `reference_profit`，原档案仍精确重放，删除一腿费率后提示具体腿。无匹配费用资产证据时拒绝估算。
- 扫描生成的 Plan 冻结费率版本。Admission、IOC/Maker 交接及首笔开仓动作均使用当前费率源核对。回归覆盖批准后改费、交接后改费、恢复后拒绝旧版本。此处验证到策略动作边界。
- 两条 Zig 定向测试分别验证本机 OKX 第三资产收费/返佣原币过账，以及 Hyperliquid Gateway 和 Owner 对收费/返佣原币、持久化重放及恢复的处理。均为离线 Venue 回报夹具。

剩余验收：现有正式 StrategyHost 未组装此跨所工作流，公共观察账户身份还须经 08 映射为部署策略的真实 ExchangeAccount。11 负责让实际运行组装提供当前费率源并从前端批准跑通开仓复核。此票保留 in-progress；当前验证不构成 Demo/Testnet 或生产资格。费率改变导致校准作用域失配时继续拒绝，使用与该作用域匹配的研究证据重新评估。
