# 设置驱动扫描 06 内部验收

日期：2026-11-16。实施基线：Ringwin `65d68ab0b643e3d8f1b7499b884c0be8dcdb1867`，RingwinUi `04d5c5c`。对应本地 `.scratch/settings-driven-scanner/issues/06-integrate-and-retire-static-config.md`；启动方法见[扫描运行](../scanner-runtime.md)。

## 复审更正及三项修复

06 和实施地图已重新打开；本节更正下方历史“内部实施项已覆盖”和无剩余缺陷的结论，不重新认定整体验收完成。本轮基线为 Ringwin `c7120fb0`、RingwinUi `75f0043`，未使用子代理。

原始复现位于 `.scratch/build/scanner-06-review/`：`probe.log` 记录实际 native 目录 ready 65，以及关闭新品种时登记 1→2／订阅 2；`recovery.log` 记录部分写入失败后重启启动 400、保存设置 200 但未发现、再次启动仍 400。上述场景未被旧检查覆盖。

- 前端目录上限改为 8192，与 Python 注册、缓存和范围持久化合同一致，保留越界拒绝。API 回归接受 65／8192 项、拒绝 8193 项，修复前在 65 项失败。
- 资产筛选重绑保持原 `registered` 集合；只有 `pending_catalogues` 标识的来源切换／首次目录接纳合并新目录。实际 native worker 回归从旧隔离资产缓存运行，发现 ETH+SOL 时登记与订阅均保持 1；修复前登记变成 2。
- 保存已有设置在本进程尚无成功发现时强制重新发现，持久化 ready 缓存不再阻止协调。回归注入范围保存失败、重启确认缓存 ready 但无法启动，再通过 `ControlPlaneApp.exchange_settings` 保存同一设置恢复筛选、启动并产出规范盘口；恢复阶段不直接调用 `discover()`。修复前保存 200 后仍保留旧资产筛选。

| 本轮检查 | 结果及证据 |
|---|---|
| 受影响 Python | 77/77 通过，153.792 秒；`PYTHONPATH=python python -m unittest test_scanner_integration test_scanner_console test_scanner_history test_exchange_settings test_control_plane_http_headers test_credential_scanner_coexistence`，`fix-affected.log`。 |
| 最终两项 native 回归 | 2/2 通过；`test_asset_rebind_preserves_registration_when_new_instruments_disabled`、`test_asset_rebind_write_failure_recovers_after_restart_by_saving_existing_settings`，`fix-final-regressions.log`。资产重绑覆盖运行中订阅保持。 |
| 大目录生产浏览器 | `node tools/verify-scanner-integration-browser.mjs --large-catalogue --settings-lifecycle --restart --refresh --output .scratch/build/scanner-06-review/fix-browser`，14 项通过，外部请求 0。实际 native worker 返回 65 项 HL，加上 OKX 共 67 项；页面配置 ETH、启动、RawIngress、双源刷新／退市／恢复、重启、改名／切环境／删除均通过。证据 `fix-browser/report.json`、`large-catalogue-view.json` 和截图。 |
| 前端 | 类型检查、生产构建及全部现有 `*.check.mjs` 通过；controlLayout 使用已有 scanner-qa Playwright 路径及 Chromium，未安装依赖。构建保留既有包体积提示。 |
| Python 全量 | `python -m unittest discover -s python`，431 项，1 失败、3 跳过，1493.324 秒，退出 1；`fix-full-python.log`。唯一失败为 `test_public_acceptance_contract_keeps_frozen_test_dependencies`，实际／预期摘要与此前 `scanner-06-baseline-contract.log` 一致，未修改冻结合同，不声明全量通过。 |
| 静态检查 | Python 编译、浏览器脚本语法、两仓库差异检查通过。 |

以上日志相对 `.scratch/build/scanner-06-review/`。Standards 自查：按两仓库 AGENTS、ADR 0001／0012 和现有目录组织核对，未发现确定的新违例。Spec 自查：按本轮三项发现核对容量、登记策略、正常保存入口及 native／页面证据，未发现确定的修复遗漏；没有执行独立子代理审查。本轮未修改 Zig 源码或重跑 Zig 全量测试，复用已有 native worker。未连接在线行情、Demo 或真实下单，未推送或部署。

## 以下为历史验收记录

## 交付行为

正常 ControlPlaneApp 从空目录组装 ScannerRuntime；不读取 `scanner-market.json`，遗留文件损坏或超容量也不影响新入口。所有品种由公共目录发现，OKX worker 必须携带动态绑定与规则。保留旧三个 InstrumentIdentity 的兼容别名仅用于身份稳定，不作为接纳列表或 worker 配置。

用户保存命名设置，在页面按来源选择 ETH／USDT、应用范围并启动后，实际 Python 调度、Zig MarketFeedAdapter、规范投影、RawIngress 与 Python 扫描产生候选。缺少经济研究材料仍为 `missing_evidence`，没有推荐或交易授权。

按用户明确补充要求，关联已核对的主网默认标准永续 BTC／ETH 标的；USDT 价格与 USDC 结算分别处理。未知、包装资产和 Testnet 不因同名关联。全部可解码市场仍动态发现，不要求用户维护资产文件。范围输入按各来源解析资产身份，报价选项按代码展示。协议来源、单位与覆盖限制见[资产关联核对](2026-11-16-scanner-observation-asset-pairing.md)。

旧缓存关联升级按来源重绑已有筛选并持久化；缓存先写、配置后写之间失败会使来源不可用，下一次发现可修复。退市保留其他消费者的订阅所有权，但撤销有效输入；重新出现遵守订阅容量并预热。重启停止且不请求公共接口，启动后必须取得本进程新目录才允许发布缓存品种的盘口。空目录停止后可通过重新保存设置恢复。生产 UI 的 `/app/` 路由可直接刷新，API 继续认证。

## 实际检查

测试只在 PublicTransport 边界提供确定性的交易所协议字节，不替换 native 适配器、规范行情或扫描结果。浏览器使用正常应用构造和生产前端构建；测试入口手动推进同一运行时调度以消除墙钟抖动。

| 检查 | 命令与结果 |
|---|---|
| Zig 全量离线 | `zig build test -Doptimize=ReleaseSafe -j2`，退出 0。日志 `.scratch/build/scanner-06-zig-full.log`。 |
| native worker | `python tools/zig-entry.py build-exe src/runtime/scanner_market_node.zig -O ReleaseSafe --stack 536870912 "-femit-bin=zig-out/bin/ringwin-scanner-market.exe"`，退出 0。Zig `0.17.0-dev.315+5b647b792`；二进制 SHA256 `98C9A649DC6F1BD53143C09A4BB13BE05EA44F78285DB37270134808779B4B38`。 |
| Python 全量 | `python -m unittest discover -s python`，426 项，2 失败、1 错误、3 跳过，未通过；失败解释见下文。日志 `.scratch/build/scanner-06-python-full.log`。 |
| 扩展受影响回归 | 92 项，OK，跳过 1 项。包含认证、历史、配置、扫描、归档与相关安全回归；日志 `.scratch/build/scanner-06-python-affected.log`。 |
| 最终受影响回归 | `PYTHONPATH=python python -m unittest test_scanner_integration test_scanner_console test_scanner_history test_exchange_settings test_control_plane_http_headers test_credential_scanner_coexistence`，76/76 通过，108.223 秒；日志 `.scratch/build/scanner-06-python-final.log`。 |
| 完整生产浏览器 | `node tools/verify-scanner-integration-browser.mjs --settings-lifecycle --restart --refresh --output .scratch/build/settings-06-browser-final`，13 项通过，外部请求 0。 |
| 草稿冲突生产浏览器 | `node tools/verify-scanner-integration-browser.mjs --draft-conflict --output .scratch/build/settings-06-browser-conflict`，9 项通过，外部请求 0。 |
| 前端 | RingwinUi 的 `npm.cmd run typecheck`、现有 scannerApi／scannerPresentation 检查和 `npm.cmd run build` 通过；构建保留已有大包体积提示。 |
| 静态差异 | `git diff --check` 与变更入口语法检查通过。 |

13 项浏览器记录包括：登录；从空设置保存两家来源并重载；动态 ETH 范围；native 深度与待评估候选；RawIngress 审计；候选保留原始证据；历史／刷新／窄屏；两来源独立规则变化、故障、容量、退市与恢复；暂停／恢复／停止；服务重启恢复且公共请求不增加；改名与名称搜索及历史；环境切换预热及实际环境；删除范围与保留历史名称。

完整组合的第一次生产页面刷新暴露 `/app/` 404，已修复并补 HTTP 回归。测试服务原地重启时还暴露旧持久连接继续引用已关闭 History 的测试夹具问题，重启验收改为先关闭旧浏览器上下文、重连新服务。最终两次生产浏览器记录均通过；早期开发浏览器的负载超时不作为通过证据。

### 全量 Python 的限制与复验

1. `test_credential_scanner_coexistence` 使用不满足当前公开合同的旧 ScannerFixture，已改为正常应用并验证凭证入口与空扫描共存，最终受影响回归覆盖。
2. `test_public_acceptance_contract_keeps_frozen_test_dependencies` 的冻结依赖摘要失败。对未修改基线 `65d68ab0` 单独归档运行，同样失败且实际／预期摘要一致，证据 `.scratch/build/scanner-06-baseline-contract.log`。没有改写冻结合同来消除基线失败。
3. `test_shared_memory_failure_stops_all_members_and_leaves_other_host_ready` 在全量负载时发生 Host 预算耗尽；单独复验通过。证据 `.scratch/build/scanner-06-python-unrelated-recheck.log`（同批另一冻结摘要测试仍失败）。没有取得全量全绿的结果。

## 审查

Standards：按 AGENTS、领域词汇、ADR 0001／0012 与目录归属检查，没有已确认的新增规范违例。Spec：按 06 与来源规格 18 检查入口、实际协议链路、身份／单位、生命周期与证据边界，没有已确认的剩余实现缺陷。

按 code-review 技能启动两路独立审查，但子代理没有本地工具访问能力；主代理发送了相关实际源码片段供补审。两路未提出确定缺陷，仅构成片段审查，不能称为完整独立仓库审查。主代理另检查了当前完整差异及调用路径，并用公开 HTTP／native／浏览器回归验证上述行为。

## 来源规格十项覆盖

| 来源规格验收项 | 实施票及证据 |
|---|---|
| 1 认证设置、名称、原子存储与冲突 | 01、05；ExchangeSettings 和 HTTP 回归、正常浏览器保存。 |
| 2 刷新、重启恢复且默认停止 | 01、04、06；生产重启浏览器及阻塞发现前无缓存盘口回归。 |
| 3 保存后直接按配置名称选范围 | 01、05、06；正常生产浏览器设置到范围。 |
| 4 无旧市场文件可运行 | 06；正常构造、缺失／损坏／超容量旧文件回归与空目录浏览器。 |
| 5 动态元数据与白名单外 OKX | 02、03、06；ETH spot／swap 与 Hyperliquid 的 native 解码、规则及盘口。 |
| 6 范围、目录、新品种与设置生命周期隔离 | 04、05、06；两来源组合刷新、改名／删除／切环境、草稿冲突及其他消费者回归。 |
| 7 Python／Zig／RawIngress 链路、schema 和单位 | 02、03、06；真实 worker、Zig 全量、协议与候选原始证据审计。 |
| 8 名称展示、搜索和历史 | 01、05、06；生产浏览器改名、删除与历史。 |
| 9 规则、单位、退市、故障、容量与恢复 | 02、03、04、06；实际协议拒绝、TTL、迟到结果、双源故障与重新预热回归。 |
| 10 完整链路、持久化、适配器合同与报告 | 01–06；本报告及前五票 Answer，保留全量检查的实际失败。 |

内部实施项已覆盖；来源规格 18 保持 open，本报告不自动修改其状态。剩余资格为在线端点、真实行情新鲜度、限流和持续运行，以及另行要求的经济／运行／生产验收。跨所关联当前仅核对 BTC／ETH，扩大资产覆盖需额外依据。没有访问交易凭证、连接在线行情、Demo 或真实下单，没有推送或部署。
