# 扫描定型UI合入主工作区与正式接线

日期：2026-11-11（Asia/Shanghai）。用户要求将前端策略分支合入`D:/github/RingwinUi`，UI以主仓库为准，并明确`/?variant=A&demo=scanner#opportunities`为定型界面，随后授权纳入正式入口。

## 合并与归属

- 主工作区当前分支为`prototype/control-plane-demo`，从`3abcf04`快进合入`spread-arbitrage-strategy-python`的`20387fe`。没有切换`main`引用，也没有push。
- 原有登录Demo、App框架、控制面、机会页、扫描Demo和模型／自检文件等11条工作区改动先逐字节备份并校验，合并后恢复。原有未提交修改不冒充本轮新实现；范围不涉及Ringwin主工作区或其他策略。
- 合并备份在UI主工作区`.scratch/build/scanner-merge-20261109/`，含manifest、preservation-report和original文件；另保留带说明的stash。临时预验证工作区删除被自动审批策略拒绝（未给详细原因），已保留`D:/github/RingwinUi-scanner-merge-20261109`，未继续尝试删除。

## 正式界面

- `/?variant=A#opportunities`为默认正式跨所页，`/?scanner=live#opportunities`兼容；定型Demo仍由`demo=scanner`进入，旧静态页由`scanner=legacy`进入。
- 正式ScannerConsole采用主工作区定型页的启停图标、四张指标卡、筛选／机会表、范围草稿及生效表、历史表与热力图、核心请求和操作记录布局。App框架、登录Demo与控制面布局保留主工作区版本。
- API仍通过真实OwnerSession／Cookie／CSRF和现有`/api/scanner`；UI不产生行情、核心回执或交易授权。批准／拒绝／撤销／超时待查仍走本地Zig权威接口。
- 延迟HTTP回归同时发现POST将请求头转为普通dict后丢失大小写无关的查找行为，导致合法小写cookie／x-owner-csrf返回401；authorize现按名称规范化后仍执行原token及CSRF值校验。公开HTTP回归先复现401（应为有会话但缺CSRF的403），修复后合法小写头通过、缺CSRF仍拒绝。
- 补充实际pause操作：先撤销候选和闭合观察事件，释放本扫描订阅，保留其他消费者；暂停后健康检查不改回Running；重新启动产生新会话并重新预热。HTTP同样要求OwnerSession和CSRF。核心批准及持仓责任未改。
- 计划收益bp使用后端`plan_atoms/reference_atoms × 10,000`，固定目标和最差路径使用同一参考；展示与排序均使用BigInt，热力图区间用精确比值判定。数量按节点Asset精度换算，非终止小数保留精确分数。未提供的$5K净边际／可执行规模／行情延迟显示—。
- 历史仍为滚动24小时内存；热力图明确只汇总当前查询页，排除删失和跨窗口事件。范围草稿与生效投影都显示环境、纳排、深度及新品种策略；切换时间范围作废在途旧查询。

## 已执行验证

- 展示回归先红后绿：精确bp、大整数、无效分母、收益排序、原子单位数量及循环分数、完整事件和热力图边界。
- `python -m unittest test_scanner_console test_scanner_history test_arbitrage_scanner`：34项通过；新增pause公共生命周期及HTTP授权接缝，确认共享订阅和新会话预热。
- UI `npm.cmd run typecheck`、API／Demo／presentation三项Node自检、`npm.cmd run build`通过。主bundle仍有超过500kB提示。
- `python -m unittest test_owner_session_security`：5项中4通过、1跳过。
- 最终全量 `python -m unittest discover -s python -p 'test_*.py'`：374项，371通过、3跳过、0失败，耗时1309.840秒。包含独立临时目录的ReleaseSafe Zig authority探针构建、原生／Python策略生命周期及Windows进程恢复；输出一条未关闭socket的ResourceWarning，未导致失败。
- 双轴审查发现并修复：数量误标资产单位、生效范围省略条件、历史范围变更后旧查询回填。复核无待处理P1/P2。
- 浏览器17组全部通过：真实本地Web、Zig authority和离线规范输入，桌面1600×1100与窄屏390×844；外部请求0、浏览器异常0。不接Venue。结果见`.scratch/build/scanner-formal-ui/browser/report.json`及截图；初轮同名文本定位歧义、空表占位行计数断言已修正。延迟回归确认旧响应确实含3条真实事件、切换范围后没有回填；实际夹具断言8000.00bp、1BTC及三个缺失指标—。
- 本轮正式脚本已合并回既有`tools/verify-scanner-browser.mjs`，归并时与通过的独立验证脚本逐字节SHA256一致，随后仅统一LF换行并通过Node语法检查，避免保留两套重复入口。命令：`node tools/verify-scanner-browser.mjs --ui-root D:/github/RingwinUi --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe --output .scratch/build/scanner-formal-ui/browser`。

真实行情、部署、真实／Demo交易、GitHub同步和12–15资格均不在本轮范围。没有用Demo回执或静态指标替代正式结果。
