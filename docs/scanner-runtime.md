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

在现有设置页的“交易所”中选择类型、填写必填名称和环境后保存；扫描范围直接显示配置名称，不需要账户、凭证或策略加载。刷新后重新登录即可恢复设置。初次运行为空，不预置交易所。

`exchange-settings.json` 保存 `exchange_settings_v1`、独立配置版本及 `identity/venue/type/name/environment`。稳定设置身份由服务端生成，名称不参与路由；同 Venue／环境禁止重复。认证接口 `GET/POST /api/exchange-settings` 复用 OwnerSession／CSRF；写入包含 `expected_version/type/name/environment`，旧版本返回 409，校验失败返回 400，存储失败返回 503。采用同目录临时文件、flush、fsync、原子替换，落盘后才更新内存与返回成功。损坏的已保存文件使启动明确失败；残留临时文件不参与恢复。

`scanner-config.json` 继续独立版本化保存范围；控制面写入的每条范围携带 `setting_id`，并校验它对应的 Venue／环境。重启恢复设置和范围，默认 Stopped，不自动请求行情。

保存 OKX 设置会异步请求公共 SPOT／SWAP 目录，已有静态来源也会发现新增品种，无需 `scanner-market.json`。发现只登记目录；应用范围并启动扫描才创建行情订阅，单来源也可观察盘口。完整动态目录、精确规则与来源证据原子保存到 `scanner-discovery.json`；重启从缓存恢复身份和范围，仍默认停止且不请求网络。发现失败保留原目录，设置仍可见并展示原因；再次保存失败的来源可重试。自动刷新／退市由 04 交付。`scanner-market.json` 目前仅是旧来源的内部过渡，06 移除旧文件。

扫描视图的 `exchanges` 独立于 `catalogue`，包含设置字段及 `source_id`（Venue／环境）、`products`、`catalogue_state`、`catalogue_error`；状态为 unloaded／registered／loading／ready／failed。目录行携带 `setting_id`。未加载、加载中和失败不移除设置选项；未保存的来源不可经控制面加入范围。交易所账户预览与这份设置分别管理；环境切换和删除的订阅协调由 05 实施。

## 支持范围

| Venue | 请求环境 | 实际公共来源 | 当前产品／目录 |
|---|---|---|---|
| OKX (1) | production | production REST | 公共元数据发现的 live／normal 现货及可明确单位的线性永续 |
| OKX (1) | demo | production 公共 REST，明确标注共享来源 | 同上，不生成 Demo 成交或资金资格 |
| Hyperliquid (21) | production | 主网公共 info REST | 默认标准永续 meta 动态目录（collateralToken=0） |
| Hyperliquid (21) | testnet | Testnet 公共 info REST | 默认标准永续 meta 动态目录（collateralToken=0） |

其他 Venue／环境／产品拒绝。Hyperliquid 没有 demo 别名，不支持现货包装资产、HIP-3 或跨报价币换算。动态观察资产按 Venue／环境／协议角色隔离，不凭同名与 OKX 配对；旧显式批准的共同资产配置仍用于原内部验收。规范 AssetIdentity 和 InstrumentRules 是配对依据。

当前在线目录和区域端点可用性没有验收，不能因本表列出协议能力就假定某个市场仍在线。实际元数据不匹配时失败关闭，不改名、回退或替换资产。

旧内部配置顶层仅含 `schema: 1`、`assets`、`bindings`。`assets` 复用扫描资产合同：`identity` 十进制字符串、`code`、`atomic_scale`。每个 binding 包含：

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

OKX 动态目录的 `specification` 返回产品、资产、状态、tick、lot、最小／最大数量和名义约束及合约面值／乘数；其规范内容摘要决定规则版本。线性合约必须明确 `ctValCcy` 为基础币、`settleCcy` 为符号报价币、`ctMult=1`，基础币 lot = 协议 lot × ctVal。其他单位返回实际拒绝原因。新增资产使用固定 18 位的小数观察表示与稳定身份，不从 lot 推导核心 AssetDefinition，也不激活核心规则或交易权限。重复发现及重启不改变品种身份；现有三个兼容品种保留原 InstrumentIdentity。

保存 Hyperliquid 设置会异步发现默认标准永续，不依赖 OKX 或手工资产／绑定清单。动态目录明确区分 USDT 价格计量和 USDC 结算（collateralToken=0），依据[官方合约规格](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/contract-specifications)。数量 lot 为 10^-szDecimals，价格坐标为 10^-(6-szDecimals)，实际盘口仍逐档校验最多五位有效数字／整数例外，依据[官方 tick／lot 合同](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/tick-and-lot-size)。观察资产固定 18 位表示，不从 lot 推导核心资产。InstrumentIdentity 绑定环境及 coin；universe 下标和所选记录／margin table 摘要进入规则版本。无效 collateral、精度、退市或缺表返回具体拒绝原因。

动态发现摘要只建立扫描观察基线；订阅和周期元数据必须重验，变化撤销健康状态，不批准核心规则或交易授权。旧显式配置仍使用原批准摘要，算法见[公共行情合同](research/2026-11-02-hyperliquid-public-market.md)。正常启动不生成研究计划、模型、校准或费率；缺项返回 pending。即时观察价差不是完整周期净收益。

## 数据与生命周期

`ControlPlaneApp → ScannerRuntime → PublicTransport → ringwin-scanner-market → MarketFeedAdapter → market.Projection → depth_snapshot → scanner.scan → ScannerConsole/History → Web`。

正常 transport 使用有超时和容量限制的公共 HTTPS REST。OKX 调用 `/api/v5/public/instruments` 和 `/api/v5/market/books?sz=5`；Hyperliquid 调用 `/info` 的 `meta` 和 `l2Book`。依据 [OKX 官方接口](https://www.okx.com/docs-v5)及 [Hyperliquid 官方接口](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)。元数据在来源启动及每 30 秒刷新，每轮轮询发布完整替换快照。

动态目录最多 8192 条；每个 OKX SPOT／SWAP 响应最多 4096 行、4 MiB，并受原有 4 MiB 捕获预算约束。实际同时订阅最多 16 个品种，超限要求缩小资产范围；每品种拥有独立 native worker／session／动态绑定，不共享注册槽位。OKX 普通行情及订阅元数据响应仍最多 120 KiB，超限明确失败，不截取部分目录。Zig 单个 OKX feed 有 16 个状态槽（3 个保留兼容、13 个动态）；畸形帧可同时撤销全部槽位的健康状态。

每个公共来源使用独立只读 native worker。private pipe 复用现有有界请求实现，校验 schema、会话、连续序号、时间和深度 codec；不涉及 StrategyHost，不增加共享内存。来源终止后迟到结果被拒绝。停止／暂停先撤销候选，然后释放自身订阅；其他消费者的所有权保留。

盘口保持来源覆盖：OKX 至多 5 档，Hyperliquid 验证来源有限快照、保留至多 8 档并标记截断。不推断不可见深度；价格／数量使用整数与分数。重复快照不刷新深度时间；过旧、乱序、冲突、断连和写入失败撤销输入。Console 独立执行 5 秒 TTL，无新帧也不保留推荐。

每个 `.raw` 来源目录使用现有 DurableStore 保存 segment、manifest 和 snapshot；RawIngress 在适配器解码前提交。每帧保留配置、实际环境、会话、原文长度、摘要及序号，大帧分段存储并可经已提交重放重新校验完整摘要。每来源会话默认捕获预算 4 MiB（含保守的记录开销预算），不是物理单文件上限。运行目录达到 64 MiB 时拒绝新来源；写入容量故障锁住订阅，需停止、归档旧来源目录并重新启动。这是资源边界，不是持续运行资格。24 小时派生历史仍是现有有界内存，无 SQLite；刷新保留，服务重启清空并更换覆盖身份，不续接中断寿命。

## 内部验收

```powershell
python -m unittest discover -s python -p test_scanner_integration.py
node tools/verify-scanner-integration-browser.mjs --ui-root D:/github/RingwinUi-scanner-integration --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe
```

浏览器 runner 只在公共 transport 返回标记为 `synthetic_protocol_fixture` 的两家协议输入。HTTP 不接受行情、候选或批准回执；内部适配器、规范投影、扫描器和认证均为正式实现。

只验证本次设置／范围改动且不构建整个前端时，可运行 `node tools/verify-scanner-integration-browser.mjs --dev --ui-root D:/github/RingwinUi`。runner 启动本地 Vite 并代理到临时认证后端，使用相同正式页面；要求现有 `ringwin-scanner-market` 二进制、Playwright 和 Chromium。设置存储及服务恢复回归为 `python -m unittest discover -s python -p test_exchange_settings.py`，范围与真实适配器回归为 `test_scanner_console.py`、`test_scanner_integration.py`。

本交付只验项目内部整合。在线端点、真实盘口、新鲜度、限流和长期运行另验；trading_qualified 恒为 false，12–15 及经济／运行／生产资格不变。

OKX 动态发现定向浏览器验收：`node tools/verify-okx-discovery-browser.mjs --dev --ui-root D:/github/RingwinUi`。仅依赖定向生成的 native worker，不需要全量构建；Zig 直接测试应沿用 build.zig 的 `--stack 536870912`，并按用例名称过滤，避免入口的传递测试扩展到无关核心模块。

Hyperliquid 动态发现复用同一浏览器 runner：`node tools/verify-okx-discovery-browser.mjs --dev --hyperliquid`。从空目录保存命名设置，经实际 Python／Zig 到页面 ETH 盘口。Hyperliquid 完整 meta 的发现和订阅重验限 1 MiB／4096 品种，普通盘口仍限 120 KiB；超限明确失败，不截取部分目录。
