# 04a：公共 MarketTrade 共享合同

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02](02-shared-domain-contracts.md)
Parent: [模块地图](../map.md)

## Question

04 需要公共成交；当前 CanonicalEvent 只有经济 Fill，没有 MarketTrade，不能挪用账户成交。

## 完成条件

- [x] 增加 Venue 中立、无账户经济归属的 MarketTrade，精确价格/数量与稳定成交身份。
- [x] codec、核心公开应用、Host 输入、版本身份、旧格式拒绝及回放测试覆盖；不增加账本或订单写入。

## Answer

本票是执行 04 时按接入手册第 6 节识别的真实共享前置任务；范围仅公共成交流。

2026-11-03：共享合同已完成。`MarketTrade` 保留规范品种、稳定身份、价格/数量、方向与源时间；
核心验证 scope、身份、时间和已激活规则，追加规范审计事实，不创建订单或经济入账。
Host type 8/schema 1 为 96-byte 独立负载，Zig/Python 均验证单位与保留位。

canonical 20 / codec 15 / journal 52 / state 56 / registry 50，native manifest 同步，旧格式拒绝。
公开入口 `src/testing/acceptance/venues/hyperliquid_market_acceptance.zig` 的最终定向矩阵
Debug、ReleaseSafe 各 13/13，覆盖核心稳定应用、明确数量单位、Host batch、规范日志与快照加尾恢复；
Python Host 边界 8/8、native 构建检查 8/8。完整套件的最终结果由父票 04 单列，不以本票定向结果替代。

起始 revision `77e57cc82ea17fcdcc4294594b3274b1187433d2`，Zig `0.17.0-dev.315+5b647b792`、Windows；
无网络或真实账户事实。两轴审查无剩余阻塞。实现与限制见
[04 实现记录](../../../docs/research/2026-11-02-hyperliquid-public-market.md)。
