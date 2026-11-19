# 01：交易所设置持久化并接入扫描范围

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Triage: ready-for-agent

来源：[18 设置驱动扫描规格](../../cross-venue-arbitrage/issues/18-settings-driven-scanner-spec.md)。无 blocker，可首先认领。

## Question

如何让用户保存交易所类型、必填名称和环境后，刷新或重启仍可恢复，并立即在扫描范围看到配置名称？

## What to build

打通设置页 → 认证控制面 → 服务端 JSON 原子持久化 → 扫描范围选项。范围直接引用已保存设置，不依赖目录是否加载成功来决定交易所是否可见。先让现有已登记来源通过此链路可选择并运行，为后续两家交易所的动态发现提供一致的最小目录合同。

## Acceptance criteria

- [x] 前端读取、创建和保存设置接入现有 OwnerSession／CSRF 控制面；类型对应已实现行情适配器，名称去空白后必填，环境明确。
- [x] 保存稳定设置身份、VenueIdentity、类型、名称、环境、schema 与版本；显示名不参与协议路由，同 Venue／环境避免重复公共来源，账户名称与交易所名称分开。
- [x] 采用同目录临时文件、flush、fsync、原子替换；成功落盘才返回成功。写入失败、残留临时文件、空名称和版本冲突不覆盖旧配置；损坏已保存文件明确报错。
- [x] 刷新页面和重启服务恢复设置；初次空配置不预置交易所，重启默认停止，不自动请求行情。
- [x] 设置保存后立即在扫描范围显示配置名称，无能力声明、资格登记或二次启用。元数据加载中／失败仍保留选项并显示实际状态。
- [x] 统一设置引用、目录状态和来源身份合同供后续发现及生命周期票使用；已有来源经前端选择、应用范围、启动后通过实际 Python／Zig 链路产生扫描输入。
- [x] 保留范围版本及独立持久化方式，不依赖交易账户启用、凭证或 StrategyInstance 加载，不添加数字交易所名称或名称缺失替代分支。
- [x] 通过设置页面／控制面行为回归与持久化失败恢复测试；保留现有扫描集成回归可用。动态市场发现和最终旧入口删除由后续票交付。

## Answer

2026-11-15 完成。用户确认保持本票原规格：公共行情扫描独立于账户凭证；未将前述凭证讨论改写成本票需求。

### 实现

- 后端 `python/opportunity_scanner/exchange_settings.py` 持久化 `exchange-settings.json`，复用扫描配置原子写入方式。设置身份由服务端分配；支持的类型、Venue、环境和产品来自同一已实现适配器目录，名称仅展示，同 Venue／环境禁止重复。
- `ControlPlaneApp` 的 `GET/POST /api/exchange-settings` 复用 OwnerSession／CSRF。初次空设置不添加默认交易所；即使没有 `scanner-market.json`，设置及扫描投影仍可读取，来源显示 unloaded。已有静态登记仅作为本票内部过渡，不要求用户为新增设置维护文件。
- 现有设置页新增服务端设置表单，保留独立的账户预览；草稿不充当已保存状态。扫描交易所选项来自 `exchanges`，与行情 `catalogue` 是否加载无关。
- 共享合同：设置 `identity/venue/type/name/environment`，来源 `source_id/products/catalogue_state/catalogue_error`，目录及已保存范围 `setting_id`。范围保留独立版本和 `scanner-config.json`；兼容旧请求时仍必须匹配已保存设置，保存时规范化稳定引用。伪造设置身份不能覆盖配置。
- 重启读取设置及范围但保持 stopped，不发起行情请求。环境切换／删除的完整协调、历史名称生命周期、动态发现和旧入口删除继续分别由 05、02／03、06 实施；本票没有关闭它们。

### 受影响验证

- Python 共 34 个受影响用例通过：`test_exchange_settings` 2、`test_scanner_console` 12、`test_scanner_integration` 18、`test_control_plane_http_headers` 1、`test_credential_scanner_coexistence` 1。故障注入只拦截设置文件替换，保留真实会话续期；修正后该项单独通过，集成模块最终 18/18 通过，新增伪造身份断言后该项再次通过。
- 存储覆盖 fsync／replace 失败保留旧文件及内存、残留临时文件、空名称、环境／类型非法、重复来源、旧版本冲突、稳定身份、损坏文件及服务恢复。HTTP 覆盖未登录 401、缺 CSRF 403、冲突 409、写盘失败 503，以及加载中／失败仍保留设置名称。
- 前端增量 `tsc --noEmit`、`scannerApi.check.mjs`、`scannerPresentation.check.mjs` 通过；仅重建验收依赖 `strategy-authority-probe` 与 `scanner_market_node.zig`，没有全量构建或全量测试。
- `node tools/verify-scanner-integration-browser.mjs --dev --output .scratch/build/settings-scanner-browser`：7/7 通过。真实设置页创建“我的现货／我的永续”、拒绝空名称及重复来源、扫描选择／应用、实际 Zig 适配器与投影产生输入、RawIngress 证据、刷新后设置与范围恢复、窄屏、暂停／恢复／停止均通过。
- 浏览器报告：`.scratch/build/settings-scanner-browser/report.json`，截图 `running.png`／`narrow.png`；外部请求 0、页面错误 0。最终浏览器及 18 项集成验证使用从当前源码定向重建的 native worker。

### 审查与边界

- Standards 轴：主代理按仓库职责目录、领域边界、复用配置写入及 Astryx 组件约定自查，未发现阻塞项。
- Spec 轴：主代理逐项核对本票八项验收与上述公开行为证据，未发现未完成项。独立子代理无法读取文件／diff；其摘录审查未确认违规，但不作为完整独立审查通过证据。
- 实现提交：Ringwin `2b698c42`，引用拒绝回归补充 `8bdd8535`；RingwinUi `6a4aa07`（均在原 main 分支，无推送）。本地规划文件保留在工作区，不混入源码提交。
- 输入仅为 transport 处的确定性合成协议，内部仍使用真实 Python 调度、Zig 解码／规范投影和扫描计算。未读取实际交易凭证、未连接真实／Demo 交易所、未下单、未部署，不能据此宣称在线或生产资格。来源规格 18 保持 open。
