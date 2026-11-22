# 12 双 IOC 单腿失败与重启恢复

Type: task
Status: resolved
Assignee:
Blocked by: [11 从前端批准跑通双 IOC 完整周期](11-dual-ioc.md)
Parent: [模块地图](../map.md)

## Question

双腿结果不一致或回报未知时如何恢复净敞口？

## What to build

按原周期与原订单查询并处理部分成交、拒绝及 Unknown，重启后从持久事实恢复。

## 验收条件

- [x] 一腿部分成交另一腿拒绝，按实际成交量修复，核对最终敞口。
- [x] 处理中重启、迟到或重复回报不产生重复下单、重复对冲和费用。
- [x] 待确认状态能在原身份下解决或显式保留；对齐最终仓位、原币费用及汇差。

## 进展

- Gateway 可按策略、周期首意图和订单意图查找已提交的原订单，校验账户及场所路由。若持久成交已保存 Venue 订单引用，查询沿用该引用。没有终态证据时保留 Unknown 及原分派身份。
- Windows 离线定向验收覆盖两个模拟场所（Venue 1 × 21，账户 20 × 30）。原周期首意图 1 的买腿目标为 10,000 lots，先收到终态回报，后收到实际 5,000 lots 的成交和重复成交。另一腿分派结果为 Unknown。重开 Writer、Gateway 分派账本和 Host checkpoint 后，Unknown 阻止激活。查询沿用原订单 2，模拟场所提交带证据的拒绝终态，Gateway 持久化该分派的解决记录。
- 恢复后的 Host 仅产生一笔 5,000 lots 的 reduce-only IOC，意图序号为 3。重复提交该意图、重新投影待成交订单以及重复成交均未生成第二笔减仓或再次记费。最终两腿仓位为零，账户原币余额分别为 393 和 600 USDC 原子单位。原周期对账仅有两笔费用，分别为 5 和 2 USDC 原子单位。按夹具汇率 0.998 归档并回读，独立汇差为 7/500000000 USDT。
- 正式 Host 已接入当前 Writer 提交屏障的周期投影。策略查询核对 Host session、激活和原周期身份，经受信角色通道转发到独立 Gateway，再经规范输入回写 Writer。启动截面仅接受查询。正式 Host 使用已提供的匹配 checkpoint，查询不会消耗交易意图序号。
- Windows 联合回归用正式 Host 和 Gateway 角色实现验证从 checkpoint 重新激活、沿用周期 7／意图 8／订单 2、回写未确认结果后继续保留 Unknown，订单总数维持 2。该回归同进程调用 Gateway 角色实现；独立 Linux 角色验收入口为 `--routed-ioc-query-only`。未使用 Demo、Testnet 或实盘。

## Answer

- 本地 WSL1（Linux 4.4）运行 `--routed-ioc-query-only` 通过。正式 Host 从 checkpoint 95 恢复，第 2 代 Host 在提交屏障 97 查询周期 7、意图 8 对应的原订单 2。受信控制端经 Unix 通道将查询送入独立 Gateway 进程。Writer 提交未确认结果后，Gateway 收到新的 Writer 快照，原订单保留 Unknown，订单数维持 2。使用角色现有的 root 控制端认证。测试目录为 Python 3.8 临时提供与 `functools.cache` 等价的标准库兼容层。
- 终态拒绝后的单笔减仓、迟到成交去重、USDC 原币费用及汇差由 Windows 的 `--ioc-recovery-only` 持久恢复场景验证。独立 Gateway 场景验证证据不足时的保留路径。验收范围为模拟场所。
