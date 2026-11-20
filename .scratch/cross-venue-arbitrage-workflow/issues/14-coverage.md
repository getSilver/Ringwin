# 14 扩大扫描范围并展示实际覆盖

Type: task
Status: resolved
Assignee:
Blocked by: [03 按用户选择生成跨产品、跨环境候选](03-pairing.md)
Parent: [模块地图](../map.md)

## Question

选择超过现有活跃上限的范围时，哪些路线刚完成双腿采样？

## What to build

订阅前过滤并共享盘口，按 Venue 调度双腿接近的采样时间，页面持续展示实际覆盖。

## 验收条件

- [x] 按适配器能力使用批量或 WebSocket，REST 按所限频、有界并发、公平轮转及退避。
- [x] 轻量报价粗筛后标示等待深度；过期候选撤出可批准列表。
- [x] 超出同时订阅能力时列出选中、已发现、待采样、新鲜、过期、不可评估、积压及全轮耗时；慢来源只影响相关路线。

## 实现证据

- OKX production 公共协议与 Hyperliquid production 标准永续使用离线合成输入，经原生解码、OwnerSession HTTP API 和归档重放验证。范围选中 20 个盘口，10 条路线完成一轮，活跃 worker 保持在 16 个以内。排除资产不请求盘口，单腿元数据挂起期间其他路线仍继续更新。
- 批量报价的正价差线索显示等待深度。两腿规范盘口满足时间差和时效才计为新鲜。范围更新后的新一轮只计算该轮采样，worker 轮转后的重复原始盘口不续期。全轮计时和过期状态通过认证 API 验证。
- REST 限速夹具验证 Hyperliquid 加权限速、429 的 Retry-After 和 OKX 独立推进。RingwinUi 提交 `8bf0e6b` 在机会页显示覆盖汇总和逐路线状态，定向 API 契约及 TypeScript 检查通过。
- 受影响的五个 Python 测试模块共 106 项通过。本票验证离线扫描覆盖。连续吞吐、运行时归档和容量测量由 [15](15-capacity.md) 接续。
