# OKX／Hyperliquid 扫描运行

现有 OwnerSession Web 控制面的只读运行组装，无需加载 StrategyInstance，不持有交易凭证、VenueAdapter、风险预留或发送能力。没有核心桥时，白名单批准返回不可用。

Python 跨场所策略实现位于 `python/strategies/cross_venue/`，机会扫描器位于 `python/opportunity_scanner/`；策略宿主和控制面继续使用各自的共享模块。

## 启动

```powershell
zig build -Doptimize=ReleaseSafe
npm.cmd --prefix D:/github/RingwinUi-scanner-integration run build
python python/control_plane_node.py --directory .scratch/run/scanner --ui D:/github/RingwinUi-scanner-integration/dist/index.html --port 8765
```

首次启动在本机终端设置 Owner 口令，并按现有 setup 结果保存 TOTP 信息。访问 `http://127.0.0.1:8765`，复用正常登录、内存 CSRF 和扫描 API。刷新需要重新认证，已有服务端历史仍可查询。

运行目录中的 `scanner-market.json` 是可信的部署目录。没有此文件时，扫描 API 返回能力不可用，不自动装载测试数据。`scanner-config.json` 由扫描范围 API 单独版本化保存；重启恢复范围，默认 Stopped。

## 支持范围

| Venue | 请求环境 | 实际公共来源 | 当前产品／目录 |
|---|---|---|---|
| OKX (1) | production | production REST | BTC-USDT 现货、BTC-USDC 现货、BTC-USDT-SWAP 线性永续 |
| OKX (1) | demo | production 公共 REST，明确标注共享来源 | 同上，不生成 Demo 成交或资金资格 |
| Hyperliquid (21) | production | 主网公共 info REST | 显式登记的标准 USDC 线性永续 |
| Hyperliquid (21) | testnet | Testnet 公共 info REST | 显式登记的标准 USDC 线性永续 |

其他 Venue／环境／产品拒绝。Hyperliquid 没有 demo 别名，不支持现货包装资产、HIP-3、全市场发现或跨报价币换算。OKX USDT 与 Hyperliquid USDC 不形成候选；共同 BTC／USDC 的 OKX 现货与 Hyperliquid 永续是内部验收配对。规范 AssetIdentity 和 InstrumentRules 是配对依据。

当前在线目录和区域端点可用性没有验收，不能因本表列出协议能力就假定某个市场仍在线。实际元数据不匹配时失败关闭，不改名、回退或替换资产。

配置顶层仅含 `schema: 1`、`assets`、`bindings`。`assets` 复用扫描资产合同：`identity` 十进制字符串、`code`、`atomic_scale`。每个 binding 包含：

| 字段 | 语义 |
|---|---|
| venue / environment / symbol / product | Venue 整数、上述环境、协议品种、spot 或 linear |
| instrument / observation_identity | 规范 InstrumentIdentity 十进制字符串／可信观察命名空间；后者不是 ExchangeAccount 授权 |
| base_asset / quote_asset | 资产目录身份及真实单位，USDT 与 USDC 独立 |
| rules_version | 正整数，绑定受批准的不可变规则 |
| tick / lot_wire / lot_base | 精确十进制：报价币每基础币的价格 tick、协议数量 lot、基础币每 lot |
| contract_value | OKX 永续额外要求：每张合约的基础币数量；lot_base = lot_wire × contract_value |
| binding | Hyperliquid 正式 `HyperliquidMarketFeed.Binding` JSON：coin、universe_index、instrument、product=isolated_linear、size_decimals、rules_version、expected_metadata_digest（32 字节数组）、price_scale/tick_atoms、quantity_scale/lot_atoms 及必要代币身份 |
| raw_budget_bytes（可选） | 每来源会话 RawIngress 上限，2048 到 4194304，默认 4 MiB |

Hyperliquid 摘要来自受批准的目录配置，不能用本次观察值自动替换。算法见[公共行情合同](research/2026-11-02-hyperliquid-public-market.md)。正常启动不生成研究计划、模型、校准或费率；缺项返回 pending。即时观察价差不是完整周期净收益。

## 数据与生命周期

`ControlPlaneApp → ScannerRuntime → PublicTransport → ringwin-scanner-market → MarketFeedAdapter → market.Projection → depth_snapshot → scanner.scan → ScannerConsole/History → Web`。

正常 transport 使用有超时和容量限制的公共 HTTPS REST。OKX 调用 `/api/v5/public/instruments` 和 `/api/v5/market/books?sz=5`；Hyperliquid 调用 `/info` 的 `meta` 和 `l2Book`。依据 [OKX 官方接口](https://www.okx.com/docs-v5)及 [Hyperliquid 官方接口](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)。元数据在来源启动及每 30 秒刷新，每轮轮询发布完整替换快照。

当前最多登记 16 个来源，单个完整协议响应最多 120 KiB；超限明确失效，不截取部分元数据继续计算。

每个公共来源使用独立只读 native worker。private pipe 复用现有有界请求实现，校验 schema、会话、连续序号、时间和深度 codec；不涉及 StrategyHost，不增加共享内存。来源终止后迟到结果被拒绝。停止／暂停先撤销候选，然后释放自身订阅；其他消费者的所有权保留。

盘口保持来源覆盖：OKX 至多 5 档，Hyperliquid 验证来源有限快照、保留至多 8 档并标记截断。不推断不可见深度；价格／数量使用整数与分数。重复快照不刷新深度时间；过旧、乱序、冲突、断连和写入失败撤销输入。Console 独立执行 5 秒 TTL，无新帧也不保留推荐。

每个 `.raw` 来源目录使用现有 DurableStore 保存 segment、manifest 和 snapshot；RawIngress 在适配器解码前提交。每帧保留配置、实际环境、会话、原文长度、摘要及序号，大帧分段存储并可经已提交重放重新校验完整摘要。每来源会话默认捕获预算 4 MiB（含保守的记录开销预算），不是物理单文件上限。运行目录达到 64 MiB 时拒绝新来源；写入容量故障锁住订阅，需停止、归档旧来源目录并重新启动。这是资源边界，不是持续运行资格。24 小时派生历史仍是现有有界内存，无 SQLite；刷新保留，服务重启清空并更换覆盖身份，不续接中断寿命。

## 内部验收

```powershell
python -m unittest discover -s python -p test_scanner_integration.py
node tools/verify-scanner-integration-browser.mjs --ui-root D:/github/RingwinUi-scanner-integration --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe
```

浏览器 runner 只在公共 transport 返回标记为 `synthetic_protocol_fixture` 的两家协议输入。HTTP 不接受行情、候选或批准回执；内部适配器、规范投影、扫描器和认证均为正式实现。

本交付只验项目内部整合。在线端点、真实盘口、新鲜度、限流和长期运行另验；trading_qualified 恒为 false，12–15 及经济／运行／生产资格不变。
