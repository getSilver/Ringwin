# 01 从空配置保存并启动扫描范围

Type: task
Status: resolved
Assignee:
Blocked by: 无
Parent: [模块地图](../map.md)

## Question

操作者如何从空目录选择并保留两腿市场？

## What to build

从注册适配器的目录逐腿选择 Venue、产品和环境，批量添加实际可选项并启动扫描。

## 验收条件

- [x] 在正式设置页保存后刷新、重登和重启，已应用范围一致。
- [x] 只在一家挂牌的排除币仅影响该来源；混选场所及产品仍可保存有效范围。
- [x] 登记第三个适配器后页面自动提供其目录，采集请求对应所选范围。

## Evidence

- `node tools/verify-scanner-integration-browser.mjs --dev --scope-ticket --output .scratch/build/scope-ticket/final` 通过 4 项。空目录经正式 OwnerSession 设置页保存 OKX Demo、Hyperliquid Testnet 和第三注册来源。批量保存 OKX 现货与永续、Hyperliquid 永续、第三来源现货。刷新、重新登录和重启恢复同一配置版本和目录。
- SOL 只由 OKX 现货目录提供。范围仅在该行保存排除。启动后观察到四个选中盘口，逐条核对了请求目标。OKX Demo 读取共享 production 公共来源，Hyperliquid 使用 Testnet 路由，第三来源使用独立的夹具端点。输入均为离线合成协议数据，第三来源复用 OKX 解码器。
- 7 项定向 Python 测试通过，覆盖设置存储、HTTP 认证及恢复、非生产路由和 Hyperliquid 原生采集。RingwinUi TypeScript 类型检查通过。
