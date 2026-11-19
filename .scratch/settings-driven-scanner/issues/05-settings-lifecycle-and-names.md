# 05：交易所修改、删除与名称展示一致性

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 交易所设置持久化并接入扫描范围](01-persist-exchange-settings.md)
Parent: [模块地图](../map.md)
Triage: ready-for-agent

来源：[18 设置驱动扫描规格](../../cross-venue-arbitrage/issues/18-settings-driven-scanner-spec.md)。

## Question

如何保证改名、删除或切换交易所环境后，扫描运行、历史展示和已保存范围保持一致？

## What to build

用户在设置页修改或删除交易所后，扫描页面及现有来源按稳定身份更新：改名仅改变显示，环境变化重建相应来源，删除同步撤销范围和订阅。先以 01 可运行的现有来源完成验证，动态发现来源的组合回归交由 06，不增加对 02／03 的依赖。

## Acceptance criteria

- [x] 所有交易所多选／筛选、名称搜索、范围草稿与生效范围、行情及故障来源、机会方向、历史、详情和操作提示统一使用设置名称，删除固定名称判断及数字名称占位。
- [x] 名称仍在保存处必填，不增加名称缺失替代分支；改名后当前与保留期内历史展示更新，稳定身份、候选身份及未受影响订阅不变。
- [x] 删除设置同步移除对应已保存扫描范围、释放本扫描器订阅并撤销相关候选；历史保留可解释的名称信息，不退化为数字名称。
- [x] 环境切换使旧来源失效并按新环境重新预热，实际来源环境如实展示；删除或切换后的旧会话迟到结果不能重新发布候选。
- [x] 设置保存与范围／运行协调失败时明确返回失败或待处理，不能报告完成却继续发布旧来源结果；重启后可恢复一致的已保存状态。
- [x] 其他交易所及其他消费者的共享订阅不受误释放，交易账户和核心交易权限不随公共扫描设置变更。
- [x] 通过设置页面操作到扫描结果的公开接口验证改名、搜索、删除、环境切换、迟到结果、协调失败和历史名称；01 的来源即可独立验收。

## Answer

2026-11-15 完成内部确定性实现；来源规格 18 与票 06 保持 open。

### 实现

- 设置按 `identity` 编辑与删除，保留原有名称必填、版本冲突、重复来源及原子写入校验。改名不改变扫描配置、候选身份或 worker；前端编辑／删除操作复用现有设置面板。
- 控制面在 console 锁内先保存设置再协调扫描范围。删除移除对应范围，仅释放本扫描器所有权；环境／类型变化保留设置身份并重建适用产品来源。协调失败返回 HTTP 503、`saved:true`、`pending:true`，先清空候选并停止扫描；重启按设置文件修复范围且默认停止。
- `scanner-config.json` 可选 `pending_catalogues` 保存环境切换后的首次目录接纳状态；首次完整发现按代码重绑观察资产筛选，之后继续原新品种策略。显式保存设置可重试失败或未完成加载；普通读取和停止重启不会发起目录请求。
- 旧轮询结果校验配置版本／session／worker，目录结果校验设置身份／环境／来源 generation，失效结果不能更新目录缓存或发布候选。其他交易所和共享消费者原 worker 不变。
- 以完整 `Venue + observation namespace` 解析候选来源，避免同一 Venue 多环境误选名称。当前行情、故障、草稿、生效范围、方向、详情和移除提示使用设置名称；历史记录附带设置身份、环境及名称快照，保留期内解析最新名称，删除后保留最后名称。规范候选和复算材料不因显示名称改写。

### 受影响验证

- 设置存储、真实 OwnerSession／CSRF HTTP → Python → 既有 Zig MarketFeedAdapter／规范投影测试按范围运行。初次 68 项检查中暴露旧测试替换 console 后未绑定设置，以及一个测试要求从仓库根目录启动；补齐测试设置并从仓库根目录运行后，相关失败项通过。
- 最终定向命令：`$env:PYTHONPATH='python'; python -m unittest test_exchange_settings test_scanner_console test_scanner_history test_scanner_integration.DynamicCatalogueTests test_scanner_integration.HyperliquidCatalogueTests test_scanner_integration.IntegrationTests.test_settings_rename_delete_and_retained_history_through_http test_scanner_integration.IntegrationTests.test_settings_reconciliation_failure_stops_and_restart_repairs_saved_scope test_scanner_integration.IntegrationTests.test_settings_environment_switch_fences_late_poll_and_keeps_other_workers test_scanner_integration.IntegrationTests.test_settings_hyperliquid_environment_switch_rebinds_saved_asset_filters test_scanner_integration.IntegrationTests.test_declared_nonproduction_routes_keep_actual_source_identity`：45/45 通过。后续 `settings_changed` 重试修正后的相关 3 项复验、HL 环境切换失败／重启／显式重试扩展回归均通过。
- 新增存储切换／删除、HTTP 历史改名与删除、协调写盘失败先失败后通过；环境切换迟到轮询、其他消费者 worker 保留、删除后的迟到目录不写缓存通过。HL 资产筛选换环境先失败后通过，并验证 pending 状态重启恢复。
- 前端 `tsc --noEmit`、`scannerApi.check.mjs`、`scannerPresentation.check.mjs`、Python 语法及两个仓库差异检查通过。未修改 Zig 源码，复用现有 native 验收程序；未做全量构建或全量测试。
- `node tools/verify-scanner-integration-browser.mjs --dev --settings-lifecycle --output .scratch/build/settings-lifecycle-browser`：10/10 通过。设置页保存／重开、范围配置、启动与盘口、证据、历史／窄屏、暂停／停止、改名及搜索／候选身份保持、环境切换及实际来源、删除及历史名称均通过。最后一轮期间前端有增量 HMR，完成后类型／展示检查通过。
- 浏览器报告：`.scratch/build/settings-lifecycle-browser/report.json`；截图 `running.png`、`narrow.png`、`lifecycle.png`。页面错误 0，外部请求 0。输入仅替换公共 transport 协议字节；未使用账户凭证、未连接真实或 Demo 交易所、未下单或部署，不构成在线／生产资格。

### 审查与提交

- 按 implement 调用 code-review 的 Standards／Spec 两路独立子代理；两者均报告没有本地文件读取、终端或工具发现能力，无法审查。不能视为独立审查通过。
- 主代理按当前 diff、仓库目录／领域边界及本票七项验收自查，修正首次目录与后续新品种策略的区分、失败后显式重试，以及草稿资产筛选重绑；未发现剩余阻塞项。动态来源完整组合与旧入口移除仍由 06 验收。
- 源码提交：Ringwin `7daf2e78`，RingwinUi `bd109e8`，均在当前 main 分支，无推送。本地 tracker 保留工作区，不混入源码提交；其他预存规划改动保持原样。

### 主代理复审与两项修复

- 2026-11-15：用户要求主代理接手未完成的独立审查。按当前源码复审确认两项 P2：目标目录暂缺 SOL 时保留旧环境排除 ID，SOL 后续回归会被误订阅；设置改名无条件把旧草稿基线提升到当前配置版本，导致其他页面删除的范围被旧草稿重新加入。Standards 轴未发现明确规范违规；本补充取代前述“未发现剩余阻塞项”的结论。
- 用户授权修复。目录首次接纳时，对暂缺资产复用目标环境的稳定观察资产身份，并将资产定义与目录共同持久化；当前目录有无该品种不影响纳入／排除意图。新定义不注册品种或授予交易权限。配置候选与目录在运行状态更新前完成持久化。前端删除改名时无条件提升草稿基线的操作，保留原 expected_version；过期草稿明确冲突，用户重载后可应用。
- 新增 `HyperliquidCatalogueTests.test_environment_switch_preserves_filters_for_temporarily_missing_assets_after_restart`：旧环境排除 SOL → 新环境目录仅 ETH → 重启 → SOL 重新出现，仅订阅 ETH；反向环境切换的显式纳入 SOL 同样保持。额外断言在 SOL 尚未回归时，重启后目标环境资产定义已保留。该测试修复前失败、修复后通过。
- 新增浏览器 `--draft-conflict` 模式：v1 草稿保留两家来源，另一调用在 v2 移除 OKX，设置页只改名后应用旧草稿。修复前实收 HTTP 200 且恢复 OKX；修复后 HTTP 409，已保存范围仍仅 Hyperliquid，放弃并重载草稿后可正常应用。
- 受影响 Python 命令（仓库根目录，`PYTHONPATH=python`）：`python -m unittest test_scanner_integration.HyperliquidCatalogueTests test_scanner_integration.DynamicCatalogueTests test_scanner_integration.IntegrationTests.test_settings_hyperliquid_environment_switch_rebinds_saved_asset_filters test_scanner_integration.IntegrationTests.test_settings_environment_switch_fences_late_poll_and_keeps_other_workers test_scanner_integration.IntegrationTests.test_settings_reconciliation_failure_stops_and_restart_repairs_saved_scope`：19/19 通过；最终新增持久化断言的单项复验通过。Python 语法、前端 `tsc --noEmit`、`scannerApi.check.mjs`、`scannerPresentation.check.mjs` 及两仓库差异检查通过。
- 浏览器：`node tools/verify-scanner-integration-browser.mjs --dev --draft-conflict --output .scratch/build/settings-draft-conflict-green`，8/8 通过；报告 `report.json`。先失败证据位于 `.scratch/build/settings-draft-conflict-red/`；浏览器外部请求 0、页面错误 0，仍使用合成公共协议与真实内部 native 链路。没有全量构建测试、联网交易或部署。
- 主代理复核修复 diff，确认稳定身份生成复用既有实现、暂缺资产元数据重启可恢复、草稿不绕过服务端乐观版本检查。修复提交：Ringwin `65d68ab0`，RingwinUi `04d5c5c`，均在当前 main，无推送。两项发现已修复，05 保持 resolved；Frontier 仍为 06，来源规格 18 保持 open。
