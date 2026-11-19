# 实现操作界面并接线生命周期操作

Type: task
Status: closed
Resolution: 已实现并通过整链路验收；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 04, 07
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

按 07 号冻结的信息架构实现真实数据的单页界面：登录、总览、持仓挂单、
风险与保证金、盈亏、操作台（RiskWarning 确认流）、命令历史；接通 04 号
命令通道与 05 号投影 API。

## Answer

已实现（2026-08-24，工作树 `D:\github\Ringwin-control-plane`）：

**Zig 侧**
- `src/control_plane_node.zig`（新，演示交易节点）：`setup` 用
  `applyCanonicalGenesis(target)` 生成两分片 genesis 日志落盘；`serve` 启动时经
  `replayForProjection` 从日志重建内存状态（单一恢复路径），随后轮询 04 号 TCP
  通道拉取签名命令，路由后经 `applyStable` 入各自权威日志并持久化段文件；
  Pause/DeRisk 后满足条件时自动补发 `lifecycle_progress` 使状态机走完 Draining→Ready。
- `src/trading_shard.zig`：`applyCanonicalGenesis` 增加 `target_identity` 参数，
  多分片 fixture 可拥有不同操作目标。
- `src/control_projection.zig`：ShardView JSON 新增 `operational_version`
  （UI 填 expected_version 用）与 mark price/保证金要求/挂单预留/OpenCost 字段。

**Python 侧**
- `python/operator_ui.html`：07 号 IA 的真实数据实现——登录页 + 六页布局，
  1s 轮询 /api/projection；高风险按钮统一走 /risk-warning → 确认弹窗 →
  /command（自动携带 warning identity 与 kill 的 latch identity）。
- `control_plane_web.py`：新增 ProjectionProvider（调 Zig 探针投影 runtime 目录下
  各 shard-*.journal）、GET /（UI 页面）与 GET /api/projection（需认证）、
  command_identity/expires_at 服务端自动填充；HIGH_RISK_KINDS 补入 kill_switch；
  RiskWarning 对 kill_switch 自动分配 referenced_latch_identity=warning_identity
  并回传 UI（修复：UI 不应要求操作员手填 latch id）。
- `control_plane.py`：CommandServer.serve_forever 加固——任何单条坏连接
  （RST/超时/坏请求）只丢弃该连接，accept 循环永续（节点持续轮询的不变量）。

**验收 `python/verify_operator_ui.py`（失败即停）**
1. 未认证读投影 401；UI 页面可加载；
2. setup + TOTP 登录；
3. 双分片投影均为 TRADING✓授权；
4. 低风险 trading_pause → 投影收敛至 ready·无授权（含 lifecycle progress）；
5. 高风险 enable_trading 走 RiskWarning 流 → 恢复授权；
6. 高风险 kill_switch 打 shard-2 → effective_authority=false 且锁存 1；
7. **重放等价**：对磁盘上两份 journal 直接跑投影探针，mode/authority/latch/version
   与服务视图逐字段一致——每一步都留下了可重放事实；
8. OperatorRecord ≥ 3 条且归属 SystemOwner。
输出 `operator_ui_acceptance=passed`。

**回归**：owner_session / control_plane_channel / control_projection 三条验收与
`zig test src\main.zig`（108/108）全部通过；fmt --check 全绿。

**排障记录**
- 曾出现 kill 在 shard-2 被拒：根因是 HTTP 提交的 kill 缺 referenced_latch_identity
  （核心按设计以 InvalidControlCommand 拒绝），并非通道问题；已按上文方案修复。
- 另曾发现旧运行遗留的孤儿 node 进程会竞争消费同一通道队列，验收脚本启动时
  现已强制清理同名进程。

## Comments

- 2026-08-24：实现完成，八阶段验收与全部既有回归通过，票关闭。
