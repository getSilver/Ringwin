# 16：24小时内存历史与独立范围配置

日期：2026-11-07。用户要求扫描历史不必跨重启保留，因此取消扫描SQLite；范围配置按用户选择独立保存为配置文件。该记录取代此前SQLite实现的当前合同，旧报告保留历史证据。

## 实现与边界

- 数据来自服务端收到的每轮完整评估发布，不是浏览器采样，也不回读核心CanonicalEvent／DurableStore。当前替换快照本身不积累历史，由`scanner_history.History`持续派生独立机会事件。
- 历史窗口为最近86,400,000毫秒：按最后观察时间保留，跨窗口事件只计一次，持续时间裁剪至窗口内；UTC、事件加权、首次评估代表值。自然低于门槛与TTL／输入中断／停止／上下文变化分开归因。
- 浏览器刷新不会清空服务端历史；扫描服务重启清空事件、批次、证据、操作记录及扫描请求展示状态。前端以历史实例身份清除旧查询结果和本地回执。核心持久批准及权威版本未改，仍可按核心身份查询。
- 独立`scanner-config.json`保留版本、范围、已登记品种快照及统计门槛；现有ControlPlaneApp默认绑定到节点控制面目录。重启加载后默认Stopped，不自动恢复扫描。使用同目录临时文件、flush/fsync和原子替换；替换失败回滚生效配置，损坏配置拒绝启动，不静默重置。没有宣称断电硬件持久性验收。
- 默认主记录50,000条、编码负载64MiB；批次缓存2,048条，证据缓存16MiB。批次／证据优先淘汰，保留事件可显示不可重放；事件／操作记录丢失明确标记`history_memory_capacity`。这些是代码容量边界，不是生产吞吐测量。
- 扫描请求身份与24小时查询记录分开，在进程内保留以支持超时待查和撤销选择，另限1,024条及64MiB，满时拒绝新请求；重启不代替核心幂等与事实恢复。
- API和UI显示实际覆盖起点、窗口、缺口；进程不足24小时或存在输入／容量／时钟缺口时不声称完整全天。完整输入缓存可以短于事件窗口，不保证所有历史事件均可复算。
- 移除扫描SQLite线程、队列、备份、引用锁定及长期分层归档；核心持久存储、审批、执行与交易许可没有改动。

## 当前验证

- `python -m unittest test_scanner_history test_scanner_console test_arbitrage_scanner`（cwd=`python/`）：33项通过。覆盖24小时边界、跨窗口事件、闭合事件过期后重新出现、冲突／重复、缓存淘汰、容量缺口、筛选分页、独立请求身份、配置重启恢复／默认停止、替换失败与损坏拒绝。
- RingwinUi：`npm.cmd run typecheck`、`npm.cmd run build`、`node src/scanner/scannerApi.check.mjs`、`node src/scanner/scannerDemoModel.check.mjs`通过；主bundle超过500kB提示仍存在。
- 离线浏览器15组全部通过：Chromium147.0.7727.15，1600×1100和390×844；本地真实Web与Zig核心、确定性规范输入。新增页面刷新保留、推进一天后历史清空、扫描服务重启后配置v1恢复且Stopped、历史与操作记录清空、核心批准v3保留。外部请求0、浏览器异常0。
- 命令：`node tools/verify-scanner-browser.mjs --playwright-module D:/github/RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs --browser C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe --output .scratch/build/scanner-memory-browser`。报告和截图位于该输出目录，日志`.scratch/build/scanner-memory-browser.log`。
- 首次新增浏览器检查因测试夹具误用`self`导致新登录码生成失败；修正为`fixture`后15组通过，未放宽生产登录或会话校验。
- `python python/verify_scanner_console.py`通过：实际本地Zig权威、Web审批／拒绝／幂等／撤销／丢失回执查询、扫描历史；断言未创建`scanner.sqlite`。
- Python全量`python -u -m unittest discover -s python -p test_*.py`：372项，367通过、2失败、3跳过，耗时1336.439秒，日志`.scratch/build/scanner-memory-python-full.log`。失败为既有`WebInstanceTests.test_secondary_config_keep_changes_only_target_and_peers_recover_from_original_repositories`（回调／预热预算耗尽）与`test_successor_lost_commit_ack_stops_and_reopen_cannot_restore_predecessor`（预期unknown、实际rejected）。两项随后原样单独复跑通过，31.356秒，日志`.scratch/build/scanner-memory-python-recheck.log`。这些测试不配置ScannerConsole；本轮未改Host切换或生产时间预算，也不把全量声明为全绿。
- 双轴审查完成：当前内存历史、JSON配置与UI修改无待处理P1/P2或目录／领域归属硬性违规；审查不替代运行证据。

未接真实Venue行情、未部署、未执行真实或Demo交易、未同步GitHub；没有进行真实连续24小时运行或生产容量验收。12–15的pending资格和16真实行情未验收边界不变。
