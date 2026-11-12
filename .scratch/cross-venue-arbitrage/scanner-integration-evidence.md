# 17 内部整合验收记录

实施日期：2026-11-11；最终核验与关闭：2026-11-12。规格：[17](issues/17-okx-hyperliquid-scanner-integration-spec.md)。启动与可信目录合同：[scanner-runtime](../../docs/scanner-runtime.md)。

## 已交付

- 指定工作区 `D:/github/Ringwin-scanner-integration`，分支 `codex/okx-hyperliquid-scanner-integration`，以 `ce085f11` 为基线。后端实施提交 `302a9b1e`、存储归属与环境隔离修复 `83cc4ca4`、正式启动资源与相对目录修复 `9a3a572d`。
- UI 独立工作区 `D:/github/RingwinUi-scanner-integration`，同名分支；基线 `393d001`，实施提交 `a4dd0ff`、精确展示与响应校验 `843a7ed`、启动文档 `9251285`。原 `RingwinUi` 未提交改动保留，没有整棵覆盖或合入主分支。
- 现有 ControlPlaneApp 自动读取可信 `scanner-market.json`，组装只读运行；`control_plane_node.py` 提供正常 Web 启动。扫描无需策略加载，未接核心时不伪造批准。
- 正式公共 HTTPS transport → 两家实际 MarketFeedAdapter → CanonicalEvent → 规范行情 Projection → 深度 codec → 既有 scanner.scan → Console／History → Web。验收仅替换外部 transport 的协议字节，HTTP 不注入候选。
- 公共环境补齐 production。支持矩阵、实际来源、受支持目录及容量以启动说明为准；USDT 与 USDC 不合并。OKX BTC／USDC 现货与 Hyperliquid BTC／USDC 标准永续构成内部测试共同配对。
- 原始捕获复用 DurableStore／DurableSink；完整大帧分段记录，已提交重放重建并核对摘要。派生历史仍为原有 24 小时有界内存，配置单独保存，不新增 SQLite。
- Web 展示规范价格、盘口金额、有限深度、来源环境、即时价差、pending 原因、规则及原始证据。没有研究计划、模型、校准和费用时不填造收益或推荐。

## 验证

编译器：`0.17.0-dev.315+5b647b792`。所有输入均为 `synthetic_protocol_fixture`，不读取交易所凭证、不连接 Venue、不发送订单。

| 检查 | 结果与证据 |
|---|---|
| HTTP → 实际适配器 → 规范投影 → 扫描 | Debug 行情进程 16/16；ReleaseSafe 行情进程最终 17/17（追加相对运行目录回归），`python -m unittest discover -s python -p test_scanner_integration.py`；最终日志 `.scratch/build/scanner-http-final.log` |
| Zig 受影响合同与分段原始捕获 | Debug 18/18，ReleaseSafe 18/18；日志 `.scratch/build/scanner-native-debug.log`、`scanner-native-safe.log` |
| 正常浏览器完整链路 | Chromium 147.0.7727.15，6/6；1600×1100 与 390×844；异常 0、外部请求 0；`.scratch/build/scanner-integration-browser/report.json` 和截图 |
| UI | typecheck、scannerApi.check、scannerPresentation.check、Vite production build 通过；保留既有大 bundle 提示 |
| 双轴审查 | Standards 的存储归属 P2 已修；Spec 的同实例环境切换／迟到输入 P2 已补回归。补审两轴剩余硬性问题均为 0；Spec 独立重跑相关三项 3/3。Worker 元组可读性是可选建议，未扩大重构 |
| Python 全量 | `python -m unittest discover -s python -p 'test_*.py'`：391 项，388 通过、3 跳过，1825.337 秒。首轮缺少本工作区 `strategy-authority-probe` 导致失败；补建后最终重跑通过。日志 `.scratch/build/scanner-python-full.log` |
| Zig 全量 | ReleaseSafe：`zig build test -Doptimize=ReleaseSafe --summary all`，889/889，6/6 构建步骤通过，另含 bounded Host I/O 程序；日志 `.scratch/build/scanner-zig-full-safe.log`。Debug 补验：889/889、退出码 0，bounded Host I/O 通过；详见下方补验记录 |

受影响 Zig 定向命令为 `python tools/zig-entry.py test src/runtime/scanner_market_node.zig -O Debug --stack 536870912 --test-filter 'OKX' --test-filter 'Hyperliquid' --test-filter 'public captures' --test-filter 'market feed'`，ReleaseSafe 替换优化参数。初次未筛选导入测试时，64 MiB 验收栈触发既有 DurableStore 大快照测试的栈探测错误；随后按仓库既有大状态入口使用 512 MiB 栈，并在正式构建入口同步，定向两种优化均通过。没有把初次失败或未完成的全量 Debug 计为通过。

### 2026-11-12 全量 Debug 补验完成

- 同一 `src/main.zig` 全量测试以 Debug、512 MiB 栈执行，保留逐项进度，最终 **889/889 通过，退出码 0**。另以 Debug 执行正式 bounded Host I/O 入口，输出 `strategy_host_bounded_io=passed`。没有筛选、跳过或减少全量测试，也没有修改产品源码。
- 编译命令：`zig test src/main.zig -O Debug --stack 536870912 --test-no-exec -femit-bin=.scratch/build/debug-diagnosis/full-debug.exe`；随后执行该二进制，以临时诊断脚本采集逐项输出和耗时。bounded Host 命令：`python tools/zig-entry.py run src/testing/integration/strategy_host_bounded_io.zig -O Debug --stack 536870912`。
- 全量墙钟耗时 `47920.375` 秒（约 13 小时 19 分钟），**包含系统休眠，不能作为纯测试计算耗时**。Windows 系统事件记录 01:41:19 因 System Idle 进入睡眠，04:41:26 转入休眠，12:18:40 记录从低功耗恢复；用户已确认系统休眠。
- 第 586 项的 `38274.094` 秒跨越该休眠区间，不代表测试死锁或该用例实际计算了十余小时。上轮“未完成”是主动中断；本轮最终结果证明全量可完成。无需据此修改交易逻辑或系统电源设置。
- 原始证据：`.scratch/build/debug-diagnosis/full-debug.log`、`timings.json`、`progress.json`、`bounded-host-debug.log`、`metadata.json`。`timings.json` 包含连续 1–889 的全部记录及退出码；完整日志以 `All 889 tests passed.` 结束。
- 验收源码 revision：`8ebcd796ea1bd9cbb51bc6206e7475006f984b9b`；源码集合 SHA-256：`65759459cfe90a794cbeeb3ba0b767c00319c1f4883efa52c98216a579bd23e6`；Debug 二进制 SHA-256：`45deb4a9bfef7b3cdd32def75a7b95f5ae8c8981b6bc944f8a8bfce9187d4372`。编译器仍为 `0.17.0-dev.315+5b647b792`。

HTTP 故障／操作向量覆盖：未登录与 CSRF、配置冲突、重复启停、暂停恢复、无目录、规则缺失与不匹配、未知数量／深度、源时间与序号回退、重复不延长 TTL、无机会、缺评估材料、传输断连与恢复、容量与原始写入失败、局部范围及共享消费者、同实例环境切换和旧 transport 晚到、配置重启恢复／默认停止及历史清空。浏览器覆盖登录、实际范围配置、Starting／Warming 到观察结果、证据、历史、刷新重新认证、窄屏、暂停、恢复、停止。

## 边界

以上只证明 17 的项目内部整合。当前端点／在线目录、真实盘口正确性、新鲜度、限流和长期运行未验收，另立行情计划；没有经济、运行或生产资格。`trading_qualified=false`，12–15 和 16 中独立的未完成条件不因此关闭。没有部署、GitHub 同步、真实或 Demo 下单。
