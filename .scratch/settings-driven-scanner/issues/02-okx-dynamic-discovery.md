# 02：OKX 动态发现品种并完成扫描

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 交易所设置持久化并接入扫描范围](01-persist-exchange-settings.md)
Parent: [模块地图](../map.md)
Triage: ready-for-agent

来源：[18 设置驱动扫描规格](../../cross-venue-arbitrage/issues/18-settings-driven-scanner-spec.md)。

## Question

如何让用户选择已配置的 OKX 后，从公共元数据发现并扫描原三个 BTC 品种之外的 Instrument？

## What to build

通过已有目录合同打通 OKX 公共元数据请求、Zig 规则解码和动态绑定、前端范围选择及规范扫描输入。同步解除 Python 白名单、Zig 固定品种枚举和固定状态数组限制，保留 MarketFeedAdapter、规范投影和 RawIngress 证据链。

## Acceptance criteria

- [x] 由设置中的交易所类型和环境选择 OKX 实现，端点和公共请求归属该实现；前端使用配置名称，无须手工登记品种及规则。
- [x] 从公共元数据获取产品、资产、交易状态、价格／数量约束及合约规格，按 01 的共享合同返回扫描目录；发现不等于订阅全市场。
- [x] Python 配置组装、native 配置、Zig 协议解码及行情适配器均支持有容量上限的动态绑定；只删除 Python 白名单不能完成本票。
- [x] 至少一个原白名单外的 OKX 品种从前端选择范围，经实际 Python 请求／Zig 适配器／规范投影进入 Python 扫描及页面行情覆盖；保留原受支持产品行为。
- [x] 验证现货数量与线性合约乘数、报价／结算资产、tick、lot 和规则版本。单位不能确定时显示实际原因且不发布有效输入，不从 lot 推测核心 AssetDefinition。
- [x] InstrumentIdentity 重复发现及重启后稳定，跨产品／合约不冲突；原始响应与来源环境可追溯，请求环境和实际公共行情环境不混淆。
- [x] schema、session、序号、单位、规则与消息容量检查保留，错误绑定不能发布健康盘口；协议夹具通过实际 MarketFeedAdapter 契约和公开扫描链路回归。
- [x] 01 的设置与目录合同保持兼容，不阻塞 Hyperliquid 票独立交付，不新增通用插件或能力声明流程。

## Answer

2026-11-15 完成。实现提交：`42f0e465`（当前 main 分支，未推送）；本地 tracker 保留在工作区，不混入源码提交。

### 实现与公开行为

- 正常 ControlPlaneApp 即使没有 `scanner-market.json` 也创建只读扫描 runtime。保存 OKX 设置后异步发现公共 SPOT／SWAP 目录；旧静态来源不会跳过发现。沿用设置 identity、配置名称和既有 OwnerSession／CSRF 接口，显示名不参与路由。注入的 CanonicalSource 仍由提供者负责来源组装，便于 Hyperliquid 独立交付。
- Python 仅拥有端点、公共请求和调度；完整响应先进入 Zig DurableStore RawIngress，再由 OKX 规则解码器校验。目录 `specification` 保留产品、资产、状态、tick／lot、最小／最大数量／名义约束及合约面值／乘数，内容摘要决定规则版本。实际订阅时再次核对该规格；错误元数据或绑定不发布健康盘口。
- 公共 `FeedInstrument` 使用有界动态槽，与执行侧原三品种 `Instrument` 类型分离；decoder／feed 的规则及盘口状态均支持绑定。每个订阅独立 native worker／session，规范事件使用绑定的 InstrumentIdentity，source fact 身份也绑定规范品种。市场观察不创建执行能力。
- 新品种和观察来源采用确定性 SHA-256 派生身份；原三个 OKX InstrumentIdentity 与已有 observation identity 保持兼容。新资产采用固定 18 位观察表示，不依据 lot 推导或激活核心 AssetDefinition。spot 数量为基础币；线性数量为 lot_wire × ctVal，要求 ctValCcy 与基础币一致、settleCcy 与符号报价币一致、ctMult=1；无法确认时记录明确拒绝原因。
- 发现不订阅全市场：目录总量上限 8192，单产品响应 4096 行／4 MiB，另受 4 MiB RawIngress 会话预算约束；活跃订阅最多 16 个，超限要求缩小资产范围。普通协议消息保持 120 KiB。单 feed 共 16 槽（3 兼容、13 动态），各订阅进程只绑定自身品种，因此活跃 16 个订阅不共享 13 个槽。
- `scanner-discovery.json` 原子保存目录和来源证据；重复发现／重启身份稳定。重启恢复设置与范围但保持 stopped，零订阅且不发网络请求。失败不替换旧目录；通过再次保存失败来源可重试。目录刷新／退市完整协调仍归 04，设置切换／删除归 05，旧入口最终移除归 06。
- 请求环境与实际来源分别记录：OKX demo 请求使用 production 公共行情，并在捕获配置及公开证据中保留区别，不宣称 Demo 行情资格。

### 定向验证

- 受影响 Python 38 项通过：`test_scanner_integration` 22、`test_exchange_settings` 2、`test_scanner_console` 12、`test_control_plane_http_headers` 1、`test_credential_scanner_coexistence` 1。完整规格校验及健康失效完善后，动态发现／ETH 扫描／设置的 6 项再次通过。
- 新公开行为覆盖：ETH-USDT 与 ETH-USDT-SWAP 从设置／范围经真实 Python 请求构造、Zig adapter、规范投影进入扫描；验证 tick=1/100、线性 base_atoms_per_lot=10^17、RawIngress 审计、稳定身份及重启停止。发现回归还覆盖旧来源不跳过发现、错误 ctValCcy、重复目录、超过 4096 行、超过旧 120 KiB 的完整响应、请求 demo／实际 production 的来源证据。
- Zig 解码入口 17/17 通过；适配器采用名称过滤的 11 项（包含原品种、盘口容量、增量、重订阅、恢复及动态绑定）通过。最后新增的“缺失规则不发布盘口、重验规则后恢复”断言加入后，动态 Zig 3 项再次通过。命令使用仓库 build.zig 既有的 `--stack 536870912`；未带该参数的初次直接测试曾因 Windows 默认栈不足失败，按既有栈设置重跑通过。
- `node tools/verify-okx-discovery-browser.mjs --dev` 最终 4/4 通过：真实登录、命名设置保存且无静态文件发现 ETH、实际 native 扫描与页面规范盘口覆盖、停止释放订阅并保留范围。报告 `.scratch/build/okx-discovery-browser/report.json`，规范投影 `scanner-view.json`，截图 `running.png`；页面错误 0，外部请求 0。
- 仅定向生成 `scanner_market_node.zig` 所属 worker，没有全量构建。直接测试适配器文件曾带入 437 个传递测试，识别后在第 35 项后停止，随后改为明确名称过滤；没有完成或声称完成全量测试。最终差异通过 `git diff --check`。

### 审查与证据边界

- Standards：主代理按实际 diff 核对职责目录、领域／执行边界、绑定容量、锁顺序和现有持久化方式；未发现剩余阻塞项。
- Spec：主代理逐项核对八项验收。材料审查指出旧来源跳过发现，已修复并新增回归；另核实 16 活跃订阅各用独立 worker，不共享 13 动态槽。
- code-review 两个独立子代理无法读取工作区或执行命令，只完成了材料层面的审查，不能作为完整独立 review 通过证据。
- 验收输入仅在公共 transport 处使用确定性合成协议；实际 Python／Zig 解码、MarketFeedAdapter、规范投影及扫描计算保留。未连接交易所、未读取真实或 Demo 凭证、未下单、未部署。在线行情及经济／运行／生产资格保持未验；来源规格 18 保持 open。
