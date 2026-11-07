# 16 离线浏览器验收

最新补验：按用户要求将扫描SQLite替换为24小时内存历史、范围配置独立JSON保存后，离线浏览器已通过15组（含刷新保留、24小时过期、服务重启清空历史／恢复配置但Stopped、核心批准保留），外部请求与浏览器异常均为0。当前报告`.scratch/build/scanner-memory-browser/report.json`，详见[内存历史记录](scanner-memory-history.md)。下文13组及SQLite描述保留此前阶段证据。

日期：2026-11-07（Asia/Shanghai）。用户重新授权浏览器验收，明确采用离线确定性输入和本地 Zig 核心；此前停止浏览器验收的要求不再限制本轮。真实行情、真实／Demo交易、部署及GitHub同步仍未执行。

## 环境与接缝

- Ringwin、RingwinUi均为独立工作区的 `spread-arbitrage-strategy-python` 分支。
- Chromium 147.0.7727.15，Playwright Core，无头浏览器；视口1600×1100、390×844。
- 浏览器直接访问现有ControlPlaneApp的本地HTTP服务及RingwinUi生产构建。OwnerSession／CSRF、SQLite历史和原生NativeAuthority均实际执行；配对批准／撤销由本地Zig authority probe持久确认，不使用前端伪造回执。
- 夹具目录、凭证及控制密钥均临时生成并清理，不读取部署凭证。页面外部请求在发送前拦截；成功运行的外部请求列表为空。
- 单元夹具的50纳秒TTL不能用于人工页面流程。`--serve-ui`专用输入一致缩放所有时间、盘口、规则、计划及校准材料，并重新绑定模型／概率校准摘要；有效期为500秒。生产扫描器和UI的到期检查未放宽。独立回归确认收益仍为8 USDT，且在截止点撤销推荐。

## 浏览器结果

13组场景通过，已重复运行确认；浏览器异常0、外部请求0。

| 场景 | 实际断言 |
| --- | --- |
| Owner登录 | 经真实登录接口进入Stopped投影 |
| 键盘与范围校验 | 方向键移动焦点、Enter切换；多Venue选择、空纳排、0下限、空上限及倒置区间拒绝 |
| 配置并发冲突 | 并发写入后拒绝旧版本草稿，保留草稿及可读错误；成功轮询不抹除提示 |
| 运行与候选 | 启动后完整快照6项；资产／模式／状态筛选、两腿产品与证据详情 |
| 核心接受与拒绝 | 本地Zig返回批准v1；旧预期版本请求被拒绝 |
| 丢失回执 | 核心已提交后注入回执丢失，UI显示unknown；按原身份查回accepted v2 |
| 撤销 | 页面提出撤销，本地核心确认v3 |
| 历史与TTL | 实际事件、UTC汇总、首页分页边界；到期变为pending且批准按钮禁用；停止清空、重启重新预热 |
| 断网恢复 | 中断浏览器读取后立即撤销展示，恢复读取后重载快照 |
| 旧会话响应 | 延迟旧GET，停止并启动新会话；隔离新响应后释放旧响应，不能恢复旧候选 |
| 窄屏 | 控件可操作、页面无横向溢出，宽表可横向滚动，证据弹窗可打开关闭 |
| 会话失效 | 移除临时会话Cookie后清空投影；刷新页面重新提供登录入口 |
| 独立Demo | 两Venue×两产品共4范围，空纳排、排除BTC、0深度上限；故障／恢复、到期、写入缺口、历史和操作记录 |

## 发现与修复

- 上轮定位超时来自脚本将默认导航按钮当作ARIA tab；正式页为button，Demo为tab。脚本现按实际可访问角色操作，不强制点击隐藏控件。
- 浏览器发现正式页的配置冲突错误会被成功轮询清掉。UI已分开保存连接错误和操作错误；回归等待超过一次轮询周期后确认冲突提示仍可见，断网恢复仍能清除连接错误。
- 截图检查发现窄屏证据JSON未完整换行。先增加内容宽度断言并确认失败，再用Astryx Text的StyleX样式允许长证据换行；保持完整内容，不截断摘要或隐藏字段。截图禁用动画，避免记录过渡态。
- 两项前端修复已提交RingwinUi策略分支：`4e11023`，尚未合并或push。
- 测试脚本的异步路由清理改为等待正在处理的请求完成；空表断言使用候选计数和证据按钮，避免将组件的“No data”占位行误作数据。
- 双轴只读复核未发现本轮待处理P1/P2。UI类型检查、生产构建、两组状态自检通过；扫描／控制台21项和离线Web→Zig核心验证通过。未修改Zig生产代码，不重复整仓65分钟核心回归；此前889/889结果另见实施记录。

## 复跑与产物

先在RingwinUi工作区运行 `npm.cmd run build`。在Ringwin工作区运行（依赖使用本机已安装的浏览器及Playwright缓存）：

```powershell
node tools/verify-scanner-browser.mjs --ui-root D:/github/RingwinUi-scanner --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe
```

结果：`scanner_browser_offline=passed; checks=13; external_requests=0; trading=false`。

- 机器报告：`.scratch/build/scanner-browser/report.json`；稳定性复跑报告：`.scratch/build/scanner-browser-repeat/report.json`。
- 截图目录：`.scratch/build/scanner-browser/`，包括运行候选、核心接受、范围冲突、窄屏、窄屏证据和多产品Demo。
- 本次只覆盖上述离线Chromium场景；未覆盖真实Venue接线、多浏览器矩阵、生产负载及容量资格。16的真实行情条件仍未关闭，12–15资格不变。
