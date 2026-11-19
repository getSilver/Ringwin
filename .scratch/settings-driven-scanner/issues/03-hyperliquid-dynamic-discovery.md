# 03：Hyperliquid 动态发现品种并完成扫描

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 交易所设置持久化并接入扫描范围](01-persist-exchange-settings.md)
Parent: [模块地图](../map.md)
Triage: ready-for-agent

来源：[18 设置驱动扫描规格](../../cross-venue-arbitrage/issues/18-settings-driven-scanner-spec.md)。

## Question

如何让用户选择已配置的 Hyperliquid 后，从公共元数据自动形成品种绑定和规则，并按前端范围运行扫描？

## What to build

复用 01 的共享目录合同，从 Hyperliquid 公共接口发现其已接入产品，经过实际 Zig 适配器形成规范行情，供页面范围选择及 Python 扫描使用。消除用户手工编写品种绑定与资产单位的前置要求；不依赖 OKX 动态发现票完成。

## Acceptance criteria

- [x] 交易所类型、配置名称和环境来自已保存设置，元数据及盘口请求、production／testnet 路由归属 Hyperliquid 实现，不依赖“非 OKX 即 Hyperliquid”的推断。
- [x] 元数据自动建立品种与规则目录，前端按统一目录合同提供产品／资产选择；动态发现不扩大适配器实际实现的产品语义。
- [x] 至少一个 Hyperliquid 动态品种由前端应用范围后，经 Python → 实际 Zig MarketFeedAdapter／规范投影 → Python 扫描输入及页面行情覆盖，不接受预造规范盘口替代验证。
- [x] 验证数量、价格、结算资产及规则单位；InstrumentIdentity 在刷新和重启间稳定，资产关联不能仅凭同名推断，更不能修改核心资产定义或交易授权。
- [x] 保留 RawIngress、实际来源环境、schema、session、序号与容量校验；错误绑定、元数据或单位不能发布健康盘口，错误状态通过扫描页面可见。
- [x] 公共扫描无账户凭证、交易启用或策略加载前置条件；不要求人工品种清单、能力声明或额外启用。
- [x] 复用 01 目录接口及既有 Hyperliquid 适配器契约，协议夹具通过完整公开扫描链路；02 未完成时也能独立验证本票。

## Answer

2026-11-15 完成。源码与运行文档提交：`bf4cb6f5`（当前 main，未推送）；本地 tracker 保留工作区，不混入源码提交。

### 实现与公开行为

- 保存 Hyperliquid 命名设置后，由显式 type／venue／environment 分派请求默认标准永续 `/info {type:meta}`，production 与 testnet 分别使用对应端点；盘口为 `{type:l2Book,coin:...}`。不依赖 OKX 目录、账户凭证、策略或人工品种／资产清单。
- 完整元数据先进入 Zig DurableStore RawIngress，再由 Hyperliquid 协议实现解析 universe、collateralToken、szDecimals、margin table、退市状态和规则摘要。与实际 MarketFeedAdapter 共用规格校验；不新增现货、HIP-3 或交易语义。订阅及周期元数据重新校验摘要，坏规则、绑定、单位或盘口不发布健康输入。
- 复用共享目录、设置名称、扫描范围和原子 `scanner-discovery.json` 缓存。InstrumentIdentity 按标准永续 namespace／环境／coin 稳定派生，不依赖 universe 排列；下标和规则摘要参与规则版本。重复发现、换序及重启不改变品种身份，重启默认停止且无订阅。
- 数量为基础币，lot=10^-szDecimals；价格坐标为 10^-(6-szDecimals)，实际 adapter 仍校验最多五位有效数字和整数例外。依官方合约规格区分 USDT 价格计量与 USDC 结算（collateralToken=0）；目录保留结算资产和规则说明，不将两者等同。
- 动态资产按 Venue／环境／协议角色分配观察身份和固定 18 位表示，不因名称一致与其他场所或环境合并，不修改核心 AssetDefinition、规则或交易权限。原显式批准配置作为 06 前的内部过渡保留。
- 目录最多 8192 条；Hyperliquid 完整 meta 最多 1 MiB／4096 品种，发现及订阅重验均不截断；普通盘口 120 KiB。沿用每来源 4 MiB RawIngress 预算、运行目录 64 MiB 和最多 16 个活跃订阅的边界。schema、session、连续序号、时间和规范深度校验保留。失败目录不替换已持久化目录，页面显示具体原因。自动刷新／退市及设置生命周期仍分别属于 04／05。

### 定向验证

- 初始公开接口回归先失败于“保存设置后目录为空”，实现后通过；真实 OwnerSession／HTTP 设置保存 → 范围应用 → Python 公共请求 → Zig adapter／规范投影 → Python scanner／页面接口完整保留。
- 受影响 Python 43 项通过：`test_scanner_integration`、`test_exchange_settings`、`test_scanner_console`、`test_control_plane_http_headers`、`test_credential_scanner_coexistence`。之后新增的大目录／换序测试通过；最终针对新发现、坏元数据、单位／绑定、环境及原 OKX 动态发现的 10 项再次通过。
- 回归覆盖 ETH 实际规范盘口、10^14 基础币原子量／lot、1/100 tick、USDT 与 USDC 独立单位、3 次已提交 RawIngress 捕获、稳定恢复、production／testnet 端点、无效 collateral／精度／退市／缺表、重复及 4097 行目录、规则变化、错误绑定／tick／book。超过 120 KiB 的完整 meta 同时通过发现及实际订阅重验，universe 换序身份保持稳定。
- `python tools/zig-entry.py test src/adapters/hyperliquid/hyperliquid_market_feed.zig --test-filter Hyperliquid --stack 536870912`：12/12 通过，最终复验同样通过；包括已有官方捕获元数据／完整盘口、现货兼容、坏帧／session、RawIngress replay、规则变化和新订阅屏障。
- 仅定向生成 `src/runtime/scanner_market_node.zig` worker（Debug、既有 512 MiB 栈），没有全量构建或全量测试。最终 `git diff --check` 通过。
- `node tools/verify-okx-discovery-browser.mjs --dev --hyperliquid`：最终 4/4 通过，验证真实页面登录、命名设置保存及空目录动态发现、ETH 规范盘口与扫描覆盖、停止释放订阅并保留范围。报告 `.scratch/build/hyperliquid-discovery-browser/report.json`，投影 `scanner-view.json`，截图 `running.png`；页面错误 0、外部请求 0。第一次 runner 使用错误产品文案“线性永续”超时，改为页面实际“永续”后通过。

### 审查与证据边界

- Standards：主代理核对当前 diff、职责目录、共享合同、原有持久化／锁顺序及执行边界；资产表改为按 identity 保留，以免同名观察资产互相覆盖。无剩余已知阻塞项。
- Spec：主代理逐项核对本票七项验收及公开调用链；价格计量／结算分离、绑定一致性、容量和旧行为均有针对性证据。
- 已调用 code-review 的两个独立子代理；两者均明确反馈无文件读取／shell 工具，未完成独立审查，不能视为独立 review 通过。
- 输入仅在公共 transport 边界使用确定性协议夹具；实际 Python／Zig 解码、MarketFeedAdapter、RawIngress、规范投影和扫描保留。未连接交易所、未读取真实／Demo 凭证、未下单、未部署。在线行情、持续运行及经济／运行／生产资格仍未验；来源规格 18 保持 open。

### 主代理复核发现与修复（2026-11-15）

主代理再次按当前源码复核，发现原交付有两项遗漏；原“无剩余已知阻塞项”结论不能覆盖这两个场景。用户授权修复后，提交 `c20ffb78`（当前 main，未推送）：

- 普通 worker 的 IPC 仍为 256 KiB，300 KiB 元数据发现 ready 后启动失败，报 `node request capacity exceeded`。将 Hyperliquid worker 的 IPC 容量对齐既有 5 MiB 外层帧边界，容纳完整元数据及 JSON 封装；实际元数据 1 MiB、盘口 120 KiB、RawIngress 预算和 native 输入检查保持不变。将原 130 KiB 大元数据回归提升至 300 KiB，先失败后通过，实际 native 发现、订阅元数据重验、规范盘口及 RawIngress audit 均保留。
- 旧配置与动态缓存按 Venue／环境／symbol 合并，导致同名动态 BTC 身份在重启时被旧绑定覆盖，缓存 ready 又阻止重新发现。恢复改为按规范观察身份（Venue、观察命名空间、InstrumentIdentity）去重，保留重启前已有的不同绑定；不把同名旧资产和动态资产强行等同，也不迁移或删除旧入口。新增重启回归先失败于动态身份丢失，修复后验证原目录身份集合、动态资产范围、默认停止和零订阅均保持，恢复不发网络请求，重新启动只订阅原选中的动态身份并产出健康盘口。
- 定向运行 `python -m unittest test_scanner_integration test_exchange_settings test_credential_scanner_coexistence`：32/32 通过；改动两文件 `py_compile` 和 `git diff --check` 通过。主代理核对最终 diff、NativeAuthority 双向容量检查、native 负载限制、缓存合并和范围选择调用链，未发现这两项修复的剩余阻塞。此次没有修改 Zig 或前端，未重复构建或浏览器测试，未做全量构建测试。
- 原独立子代理只反馈无法使用工具，没有提供实际调用失败记录；具体原因未定位，不应视为已确认的环境工具缺失。此次修复与复核均由主代理完成，不新增独立审查通过结论。来源规格及在线／交易资格边界保持不变。
