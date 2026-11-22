# 13 Maker 撤换单、增量对冲与恢复

Type: task
Status: resolved
Assignee:
Blocked by: [11 从前端批准跑通双 IOC 完整周期](11-dual-ioc.md)
Parent: [模块地图](../map.md)

## Question

Maker 撤中成交后策略如何只对冲真实增量？

## What to build

将 Maker 报价、撤换、成交及对冲关联至同一周期和原订单，支持任一腿作 Maker。

## 验收条件

- [x] 两种 Maker 腿分别完成报价、部分成交、撤换与退出；撤单建议可到达对应 Gateway。
- [x] 撤中成交时结合已应用成交和在途对冲计算净增量。
- [x] 撤单结果未知或重启后按原身份恢复，核对迟到成交、最终敞口及账务。

## Answer

- 首笔 PostOnly 报价占用批准路线的两腿。后续 IOC 对冲与替代报价沿用周期身份。Writer 将撤单建议映射到原订单和原 Gateway 路由。替代单保留前序订单 ID，旧报价达到终态且已应用成交与报告累计量一致后，才按剩余数量重新准入。
- Windows ReleaseSafe 的 `--formal-maker-only` 联测两次通过。Venue 1 × 21 均为 simulation，账户 20 × 30、品种 101 × 102，分别作为 Maker 腿。正式 Host 进程从夹具包接收触发，Writer 提交报价与撤单，经同进程 Gateway 分派给对应的模拟适配器。联测使用合成 Venue 回执，实际 Maker 状态机另有 Python 回归。
- 两个场景均从周期 7、订单 1 出发。已应用 2,000 lots 后建立首笔对冲，待撤期间新增 1,000 lots 时仍只对冲 1,000 lots。撤单结果未知后从 Host checkpoint 恢复，查询仍指向意图 7、订单 1 和原 Venue 订单。终态报告累计 4,000 lots，迟到的 1,000 lots 补齐前未产生替代单。对冲结清后仅报价剩余的 6,000 lots。
- 两腿各以 10,000 lots 退出，持仓归零。各账户原币费用均为 5 原子单位，Maker 腿实现收益为 3 原子单位。账户对账归档并提交周期闭合后，Writer 从持久存储恢复得到一致的规范状态摘要。
- `test_arbitrage_maker` 和 `test_arbitrage_cycle` 共 45 项通过，覆盖两种 Maker 腿的实际策略输出和 Unknown checkpoint 恢复。另通过 `--formal-dual-ioc-only` 与 `--formal-ioc-query-only` 定向回归。未使用 Demo、Testnet 或实盘连接。
