# OKX／Hyperliquid 扫描运行

当前前端与默认运行入口的业务断点、用户确认的产品与环境配对规则，以及广域扫描优化方案见[跨所价差套利业务审计与优化建议](research/2026-11-19-cross-venue-arbitrage-workflow.md)。

现有 OwnerSession Web 控制面的只读运行组装，无需加载 StrategyInstance，不持有交易凭证、VenueAdapter、风险预留或发送能力。没有核心桥时，白名单批准返回不可用。

Python 跨场所策略实现位于 `python/strategies/cross_venue/`，机会扫描器位于 `python/opportunity_scanner/`；策略宿主和控制面继续使用各自的共享模块。

## 启动

```powershell
python tools/zig-entry.py build-exe src/runtime/scanner_market_node.zig -O ReleaseSafe --stack 536870912 "-femit-bin=zig-out/bin/ringwin-scanner-market.exe"
python tools/zig-entry.py build-exe src/testing/integration/control_projection_probe.zig -O ReleaseSafe --stack 536870912 "-femit-bin=zig-out/bin/ringwin-control-projection.exe"
npm.cmd --prefix D:/github/RingwinUi run build
python python/control_plane_node.py --directory .scratch/run/scanner --ui D:/github/RingwinUi/dist/index.html --port 8765
```

Web 默认使用 `zig-out/bin/ringwin-control-projection`（Windows 带 `.exe`）读取核心目录内的 `shard-*.journal`。用 `--core-directory` 指向独立的核心目录，省略时使用 `--directory`。用 `--projection-probe` 可指定已安装的探针路径。登记以已封存部署中的生效资产定义和环境为准。目录没有登记时，扫描页面按来源和品种显示缺少的敞口、报价或结算代码。

候选详情显示两腿的 AssetIdentity、登记版本、原子精度与合约数量换算。OKX 线性合约按 `ctVal` 将协议数量换算成敞口数量，盘口计算保留固定观察精度。关联刷新时先撤销旧候选，完成当前登记下的目录重建和盘口预热后再生成候选。本次运行的历史复算材料保留当时的绑定和合约单位。

首次启动在本机终端设置 Owner 口令，并按现有 setup 结果保存 TOTP 信息。访问 `http://127.0.0.1:8765`，复用正常登录、内存 CSRF 和扫描 API。刷新需要重新认证，已有服务端历史仍可查询。

在现有设置页的“交易所”中选择类型、填写必填名称和环境后保存；扫描范围直接显示配置名称，不需要账户、凭证或策略加载。刷新后重新登录即可恢复设置。初次运行为空，不预置交易所。

`exchange-settings.json` 保存 `exchange_settings_v1`、独立配置版本及 `identity/venue/type/name/environment`。稳定设置身份由服务端生成，名称不参与路由；同 Venue／环境禁止重复。认证接口 `GET/POST /api/exchange-settings` 复用 OwnerSession／CSRF；写入包含 `expected_version/type/name/environment`，旧版本返回 409，校验失败返回 400，存储失败返回 503。采用同目录临时文件、flush、fsync、原子替换，落盘后才更新内存与返回成功。损坏的已保存文件使启动明确失败；残留临时文件不参与恢复。

`scanner-config.json` 继续独立版本化保存范围；控制面写入的每条范围携带 `setting_id`，并校验它对应的 Venue／环境。重启恢复设置和范围，默认 Stopped，不自动请求行情。

保存交易所设置会异步发现对应公共目录：OKX SPOT／SWAP，Hyperliquid 默认标准永续 meta。发现只登记目录；应用范围并启动扫描才订阅盘口。目录、规则和证据原子缓存到 `scanner-discovery.json`；重启恢复身份与范围，仍默认停止、不请求网络。失败保留命名选项和原因，显式重新保存可重试。正常入口完全忽略退役的 `scanner-market.json`；无该文件或遗留文件损坏均不影响启动，不再接收手工品种清单。

扫描视图的 `exchanges` 独立于 `catalogue`，包含设置字段及 `source_id`（Venue／环境）、`products`、`catalogue_state`、`catalogue_error`；状态为 unloaded／registered／loading／ready／failed。目录行携带 `setting_id`。未加载、加载中和失败不移除设置选项；未保存的来源不可经控制面加入范围。交易所账户预览与设置分别管理；环境切换和删除协调对应范围和订阅。

## 支持范围

| Venue | 请求环境 | 实际公共来源 | 当前产品／目录 |
|---|---|---|---|
| OKX (1) | production | production REST | 公共元数据发现的 live／normal 现货及可明确单位的线性永续 |
| OKX (1) | demo | production 公共 REST，明确标注共享来源 | 同上，不生成 Demo 成交或资金资格 |
| Hyperliquid (21) | production | 主网公共 info REST | 默认标准永续 meta 动态目录（collateralToken=0） |
| Hyperliquid (21) | testnet | Testnet 公共 info REST | 默认标准永续 meta 动态目录（collateralToken=0） |

其他 Venue／环境／产品拒绝。Hyperliquid 没有 demo 别名，不支持现货包装资产、HIP-3 或跨报价币换算。市场与观察来源身份保持 Venue／环境隔离。标准永续敞口与报价按核心登记查找，使用共享的 18 位观察精度。USDT 报价与 USDC 结算分别记录，Testnet 保留独立资产空间。未登记的代码保留来源身份；没有可验证数量换算的缩放标签不能继承普通资产身份。

当前在线目录和区域端点可用性没有验收，不能因本表列出协议能力就假定某个市场仍在线。实际元数据不匹配时失败关闭，不改名、回退或替换资产。

`scanner-discovery.json` 是程序管理的目录缓存，包含 schema、观察资产、动态绑定与来源证据，不是配置入口。盘口 worker 只接受发现的绑定与规则，OKX 不再接受三个 BTC 枚举作为扫描配置。资产、tick、协议 lot、基础币 lot 和合约乘数均由发现结果校验；用户只保存交易所及扫描范围。

OKX 动态目录的 `specification` 返回产品、资产、状态、tick、lot、最小／最大数量和名义约束及合约面值／乘数；其规范内容摘要决定规则版本。线性合约必须明确 `ctValCcy` 为基础币、`settleCcy` 为符号报价币、`ctMult=1`，基础币 lot = 协议 lot × ctVal。其他单位返回实际拒绝原因。新增资产使用固定 18 位的小数观察表示与稳定身份，不从 lot 推导核心 AssetDefinition，也不激活核心规则或交易权限。重复发现及重启不改变品种身份；现有三个兼容品种保留原 InstrumentIdentity。

保存 Hyperliquid 设置会异步发现默认标准永续，不依赖 OKX 或手工绑定清单。价格通常以 USDT 计量、USDC 结算（collateralToken=0）；HYPE／PURR 按[官方合约规格](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/contract-specifications)以 USDC 计价。数量 lot 为 10^-szDecimals，价格坐标为 10^-(6-szDecimals)，实际盘口逐档校验最多五位有效数字／整数例外，依据[官方 tick／lot 合同](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/tick-and-lot-size)。观察资产固定 18 位表示，不从 lot 推导核心资产。InstrumentIdentity 绑定环境及 coin；universe 下标和所选记录／margin table 摘要进入规则版本。无效 collateral、精度、退市或缺表返回具体拒绝原因。

动态发现摘要只建立扫描观察基线；订阅和周期元数据必须重验，变化撤销健康状态，不批准核心规则或交易授权。元数据摘要算法见[公共行情合同](research/2026-11-02-hyperliquid-public-market.md)。正常启动不生成研究计划、模型、校准或费率；缺项返回 pending。即时观察价差不是完整周期净收益。

## 数据与生命周期

`ControlPlaneApp → ScannerRuntime → PublicTransport → ringwin-scanner-market → MarketFeedAdapter → market.Projection → depth_snapshot → scanner.scan → ScannerConsole/History → Web`。

正常 transport 使用有超时和容量限制的公共 HTTPS REST。OKX 调用 `/api/v5/public/instruments` 和 `/api/v5/market/books?sz=5`；Hyperliquid 调用 `/info` 的 `meta` 和 `l2Book`。依据 [OKX 官方接口](https://www.okx.com/docs-v5)及 [Hyperliquid 官方接口](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)。元数据在来源启动及每 30 秒刷新，每轮轮询发布完整替换快照。

公共 transport 不发送 `User-Agent`，通过请求私有的 urllib opener 禁用默认 `Python-urllib` 标识；不修改全局 opener、系统代理或 TLS 验证。该默认标识在本机网络对 OKX 触发 HTTP 403／Cloudflare 1010；省略字段后在线时间、永续目录和盘口返回业务码 0。HTTP 线上请求回归同时覆盖 GET 和 JSON POST。网络超时、目录解码与规则拒绝仍独立报告，接口可达不表示整个目录已被接纳。

动态目录最多 8192 条；每个 OKX SPOT／SWAP 响应最多 4096 行、4 MiB，并受原有 4 MiB 捕获预算约束。实际同时保留最多 16 个盘口 worker。广域范围按路线轮转，释放闲置 worker 时保留其最近的规范盘口供 TTL 检查。OKX 普通行情及订阅元数据响应仍最多 120 KiB，超限明确失败，不截取部分目录。Zig 单个 OKX feed 有 16 个状态槽（3 个保留兼容、13 个动态）；畸形帧可同时撤销全部槽位的健康状态。

每个公共来源使用独立只读 native worker。private pipe 复用现有有界请求实现，校验 schema、会话、连续序号、时间和深度 codec；不涉及 StrategyHost，不增加共享内存。来源终止后迟到结果被拒绝。停止／暂停先撤销候选，然后释放自身订阅；其他消费者的所有权保留。

盘口保持来源覆盖：OKX 至多 5 档，Hyperliquid 验证来源有限快照、保留至多 8 档并标记截断。不推断不可见深度；价格／数量使用整数与分数。重复快照不刷新深度时间；过旧、乱序、冲突、断连和写入失败撤销输入。Console 独立执行 5 秒 TTL，无新帧也不保留推荐。

每个 `.raw` 来源目录使用现有 DurableStore 保存 segment、manifest 和 snapshot；RawIngress 在适配器解码前提交。每帧保留配置、实际环境、会话、原文长度、摘要及序号，大帧分段存储并可经已提交重放重新校验完整摘要。每来源会话默认捕获预算 4 MiB（含保守的记录开销预算），不是物理单文件上限。运行目录达到 64 MiB 时拒绝新来源；写入容量故障锁住订阅，需停止、归档旧来源目录并重新启动。这是资源边界，不是持续运行资格。24 小时派生历史仍是现有有界内存，无 SQLite；刷新保留，服务重启清空并更换覆盖身份，不续接中断寿命。

## 实际扫描覆盖

广域扫描先按已保存的范围和登记的经济敞口生成跨 Venue 路线。OKX 按产品批量读取 tickers，Hyperliquid 批量读取 allMids。正价差线索显示为等待深度，并优先进入这一轮的双腿采样。中间价或最优价用于排序。所有发现的路线都轮转。本轮已采样且仍有近期深度的低价差路线可以暂缓重复轮询。评估与批准继续使用 native worker 生成的规范深度。

每 Venue 至多两个同时进行的盘口任务。轮转尽量同时发出两腿深度请求，慢请求期间继续发布已返回的结果。OKX 公共请求间隔至少 100 ms，Hyperliquid 按每权重 60 ms 调度，限流后按服务端提示退避。参考 [OKX 公共行情](https://www.okx.com/docs-v5/en/#order-book-trading-market-data) 和 [Hyperliquid 限频](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/rate-limits-and-user-limits)。

机会页显示选中盘口数、发现的路线数、各采样状态、当前积压及上一轮耗时。全轮耗时在每条路线都取得满足时差约束的双腿深度后更新。采样时间使用该次配对的较早一腿，健康和时效按当前时间判断。页面最多展示 256 条覆盖明细，聚合统计覆盖完整范围。评估快照受 256 条候选和 64 个规范观察的输入边界约束，优先纳入新鲜路线。过期候选会解除推荐、失去批准资格。

## 机会评估

节点在每轮扫描读取通过 `publish_inputs()` 原子登记的 `scanner-evaluation.json`，结合当前盘口及手动费率生成完整周期计划。字段见[参数包合同](research/2026-11-17-scanner-runtime-evaluation.md#实际输入发布合同)。同次系统启动内，扫描进程可重用系统单调时钟域。Windows 使用操作系统启动时间，Linux 使用启动身份和时钟命名空间。时钟身份变化或无法确认时，材料须按新身份登记。校准、资金、风险和参数包沿用原有效期。

机会页按独立档位计算 5,000 报价币参考名义金额的净边际。当前盘口下买腿的已校验入场金额须等于该档金额。可执行量受已检查的双腿数量和策略原始量约束。计划净收益以报价币显示。逐腿行情年龄以本轮评估截止时间为准。失效档位撤回并显示原因。归档记录可复算的计划、名义金额、数量、盘口和输入版本。

## 从机会页批准交易路线

机会详情从 engine 读取当前 StrategyInstance 及其 VirtualPortfolio。提交时，Web 核对扫描配置、费率版本及页面所见的评估引用。评估过期或被后续评估替换时，页面提示重新查看。核心 Writer 按候选的两腿、方向和模式处理批准。同一观察路线可以使用不同的行情端点和部署账户。批准回执同时显示两腿各自的观察来源和部署身份。

监督器通过 `control_plane_node.py --engine-authority-fd` 提供有界中继。`P` 用于读取实例、名单、版本、批准回执和撤销回执。监督器开放 `Q` 并为 Web 启动添加 `--engine-pair-approval` 后，机会页可批准路线，策略页可撤销批准。中继按命令字节和小端 32 位长度转发请求，回复为小端 32 位长度加 JSON。两种操作由同一 Writer 提交，回复携带版本和屏障。批准与交易启用和订单发送权限分别生效。

策略页显示有效名单和当前规则已不适用的批准。撤销与回执查询使用策略、组合及批准身份。输入支持策略页显示的 `0x` 十六进制身份和机会页显示的十进制身份。请求结果丢失时可用同一身份查询撤销回执或重试。批准历史达到 256 条时拒绝新增批准。核心为每条批准预留独立的撤销回执位置，因此仍可撤销。

默认使用观察和部署共用的规范 InstrumentIdentity。若部署采用不同身份，在 Web 状态目录维护 `scanner-trading-instruments.json`，键为 `Venue:请求环境:观察品种`，值为包含十进制字符串 `instrument` 和可选 `account` 的对象。例如 `{"1:demo:201":{"instrument":"103","account":"20"}}`。每腿独立按请求环境、品种、产品、基础资产、结算资产和投资组合份额核对，账户须唯一。观察命名空间和实际行情环境继续随回执提供，分别用于核对行情证据。

## 内部验收

```powershell
python -m unittest discover -s python -p test_scanner_integration.py
node tools/verify-scanner-integration-browser.mjs --ui-root D:/github/RingwinUi --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe
```

浏览器 runner 只在公共 transport 返回标记为 `synthetic_protocol_fixture` 的两家协议输入。HTTP 不接受行情、候选或批准回执；内部适配器、规范投影、扫描器和认证均为正式实现。

只验证本次设置／范围改动且不构建整个前端时，可运行 `node tools/verify-scanner-integration-browser.mjs --dev --ui-root D:/github/RingwinUi`。runner 启动本地 Vite 并代理到临时认证后端，使用相同正式页面；要求现有 `ringwin-scanner-market` 二进制、Playwright 和 Chromium。设置存储及服务恢复回归为 `python -m unittest discover -s python -p test_exchange_settings.py`，范围与真实适配器回归为 `test_scanner_console.py`、`test_scanner_integration.py`。

本交付只验项目内部整合。在线端点、真实盘口、新鲜度、限流和长期运行另验；trading_qualified 恒为 false，12–15 及经济／运行／生产资格不变。

OKX 动态发现定向浏览器验收：`node tools/verify-okx-discovery-browser.mjs --dev --ui-root D:/github/RingwinUi`。仅依赖定向生成的 native worker，不需要全量构建；Zig 直接测试应沿用 build.zig 的 `--stack 536870912`，并按用例名称过滤，避免入口的传递测试扩展到无关核心模块。

Hyperliquid 动态发现复用同一浏览器 runner：`node tools/verify-okx-discovery-browser.mjs --dev --hyperliquid`。从空目录保存命名设置，经实际 Python／Zig 到页面 ETH 盘口。Hyperliquid 完整 meta 的发现和订阅重验限 1 MiB／4096 品种，普通盘口仍限 120 KiB；超限明确失败，不截取部分目录。

合并目录的后端登记、范围持久化和前端响应校验上限均为 8192 项；目录容量不等于活跃订阅容量。超过 64 项的完整页面回归可运行 `node tools/verify-scanner-integration-browser.mjs --large-catalogue`。

已应用扫描范围内的动态来源每 30 秒后台刷新完整目录；失败同周期重试，目录 TTL 为 90 秒（进程内单调时间，重启不继承新鲜度）。刷新不阻塞其他来源的盘口轮询。加载和失败保留命名设置选项；`market.discovery` 提供状态、错误、拒绝原因、完整性及成功目录数量。TTL 到期或刷新失败即撤销该来源的有效输入和候选，恢复后重验元数据并取得新盘口。

周期刷新仅由运行中的扫描范围或其他消费者实际持有的订阅驱动。服务重启恢复设置和范围后默认停止、不自动请求目录；暂停或停止后若无其他消费者，也不继续周期请求。保存设置等显式加载动作仍可发现目录。完整目录按来源替换登记：缺失或被拒绝品种的输入、候选和扫描订阅立即失效；其他消费者的所有权保留，但不再取得该品种的有效输入，重新出现后预热。

成功刷新按来源替换动态目录，删除消失、暂停或退市的品种；规则变化关闭旧 worker／session，清空旧盘口后按新规则重新预热。新增品种受已保存的 `new_instruments`、产品及资产纳入／排除控制；关闭开关只保留配置保存时的登记身份。深度门槛仍在每次新盘口发布时以报价资产单位判定。超过 16 个盘口的范围继续轮转。多个路线复用同一盘口；映射到同一公共市场的同轮请求共享原始响应，各请求环境保留独立规范身份。其他消费者的订阅所有权独立保留。

当前声明范围为 [OKX instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments) 的完整 SPOT／SWAP 响应，以及 [Hyperliquid 标准永续 meta](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals) 的完整 universe；这两个目录请求没有分页游标。Hyperliquid 时间区间查询的分页规则不适用于 meta；不把历史查询或 HIP-3 分页纳入目录范围。完整数组由实际 Zig 协议实现解码；消息、行数、驻留目录或捕获容量超限均失败，不截断后标记完整。

刷新定向浏览器验收为 `node tools/verify-okx-discovery-browser.mjs --dev --refresh`，Hyperliquid 追加 `--hyperliquid`。确定性序列覆盖新增、规则变更、断连、容量、消失和恢复，仍仅替换公共 transport 字节。

设置支持按稳定 `identity` 编辑和删除；删除请求为 `{operation:"delete", identity, expected_version}`。
改名不修改扫描配置、候选身份或 worker，会同步到当前来源、搜索和保留期内历史展示。
历史保留来源的设置身份、环境和名称快照；删除设置后仍显示删除前最近的名称。原始规范候选及复算材料不因显示名称变更而改写。

删除撤销该设置的已保存范围及扫描器订阅；环境或类型切换保留设置身份，按新来源重建适用产品范围并预热。
新环境首次目录接纳通过 `scanner-config.json` 中可选的 `pending_catalogues` 持久化，按资产代码重绑观察筛选，完成后恢复原 `new_instruments` 策略。
暂未出现在目标目录的资产也按目标环境的稳定观察身份重绑并持久化，后续重新出现时继续遵守原纳入／排除条件。
同来源的普通资产关联升级只重绑筛选，保留原登记集合，不能借此绕过关闭纳入新品种。
公共网络轮询及目录发现的旧结果经配置版本、worker 实例和来源 generation 校验后丢弃；其他消费者持有的旧来源订阅不释放。

设置文件先原子保存，再协调扫描范围和运行。协调失败返回 HTTP 503、`saved:true`、`pending:true`，立即停止扫描并清空候选；设置保存本身失败则保持原状态。
重启默认停止，按设置文件修复已保存范围；显式重新保存设置可重试未完成目录加载，不因普通读取或停止状态自动联网。
目录缓存已写入而重绑后的范围写入失败时，重启后保存原设置会重新发现并修复筛选；缓存中的 ready 不会跳过本进程尚未完成的协调。
定向页面验收：`node tools/verify-scanner-integration-browser.mjs --dev --settings-lifecycle`。
改名只更新草稿名称，不提升草稿基线版本；配置已变化时应用旧草稿返回版本冲突，需要重新加载范围后再应用。定向冲突回归追加 `--draft-conflict`（单独运行该模式）。

06 组合验收：`node tools/verify-scanner-integration-browser.mjs --dev --settings-lifecycle --restart --refresh --output .scratch/build/settings-06-browser-full`。从空目录经过正常 ControlPlaneApp 构造、Owner 登录、两家设置、ETH 范围、实际 Zig 解码／证据和扫描，覆盖双来源刷新故障与恢复、重启停止且公共请求计数不增、名称及环境生命周期。

报价下拉按代码去重；添加范围时，资产和报价条件逐来源解析，金额按该来源精度转换，不把同名显示项当作共同资产授权。资产关联升级或环境切换重绑范围后持久化；写入失败撤销输入并显示错误，重启显式发现可恢复。合成协议仅替换公共 transport，无账户凭证、下单或生产资格。
