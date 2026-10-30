# 构建最小控制面与管理操作界面

Label: wayfinder:map
Status: closed

## Destination

交付一个可运行的最小控制面与本地 Web 操作界面：SystemOwner 经 TOTP OwnerSession 登录后，
能查看各 TradingShard 的 OperationalMode、SafetyGate、持仓、挂单与对账差异只读投影，
并通过 RiskWarning 确认流签发 EnableTrading、TradingPause、CancelOpenOrders、DeRisk/Flatten
与 KillSwitch 等 ControlCommand；命令经受限本地通道进入各分片单写者日志，权威状态始终只属于
TradingShard。一条失败即停的自动验收覆盖登录→投影→签发→核心生效全链路。部署以 Windows 开发
节点可运行为准，不含生产部署资格。

## Notes

- 领域词汇见 [CONTEXT.md](../../CONTEXT.md)；控制面操作语义上游为
  [安全与操作者授权](../quant-trading-system/issues/20-security-and-operator-authorization.md)
  与[操作者生命周期工作流](../quant-trading-system/issues/26-operator-lifecycle-workflows.md)。
- 每张 grilling 票先调用 grilling 与 domain-modeling 技能；新领域词条（如 ControlPlane）
  随票沉淀进 CONTEXT.md。
- 控制面进程用纯 Python 标准库实现；全系统仍只用 Zig 与 Python 标准库。
- 与[完成交易核心系统闭环](../trading-core-system-closure/map.md)并行推进：消费其已冻结的
  ControlCommand、OperationalMode 与 journal seam；seam 以该图冻结版本为准。
- 不变量：TradingShard 单写者；控制面失联后交易面在现有 ConfigEvent/RiskLease/凭证有效期内继续；
  KillSwitch 本地强制不因控制面失联自动解除。

## Route

- [冻结控制面产品闭环与权威所有权](issues/01-freeze-control-plane-contract.md)
- [研究 Python 标准库控制面技术基础](issues/02-research-python-stdlib-foundations.md)
- [确定 ControlCommand 注入通道与失联降级设计](issues/03-design-command-channel.md)
- [实现签名命令注入通道](issues/04-implement-command-channel.md)
- [实现分片稳定日志只读投影](issues/05-implement-read-projection.md)
- [实现 OwnerSession 认证与 RiskWarning 确认后端](issues/06-implement-auth-and-risk-warning.md)
- [原型并冻结操作界面信息架构](issues/07-prototype-operator-ui.md)
- [实现操作界面并接线生命周期操作](issues/08-implement-operator-ui.md)
- [形成控制面整波自动验收](issues/09-control-plane-wave-acceptance.md)
- [关闭波次并沉淀证据](issues/10-close-control-plane-wave.md)

## Frontier

暂无——波次已关闭（10/10 票全部闭合）。

## Decisions so far

- [关闭波次并沉淀证据](issues/10-close-control-plane-wave.md) — README（中英）新增控制面章节与边界声明；CONTEXT.md 词条核对完成；地图决策补齐、fog 清空；声明下一候选波次：生产部署资格 / Ed25519 签名升级 / 热备切换操作界面。
- [形成控制面整波自动验收](issues/09-control-plane-wave-acceptance.md) — 单入口 `python verify_control_plane_wave.py` + `tools\verify-control-plane-wave.ps1`：八阶段覆盖认证限速/CSRF/RiskWarning 栅栏/命令幂等/四分片定向投递/KillSwitch/失联降级（节点存活、日志不变、锁存不解除）/磁盘日志重放逐字段等价；`control_plane_wave_acceptance=passed`。

- [实现操作界面并接线生命周期操作](issues/08-implement-operator-ui.md) — `control_plane_node.zig` 演示节点（genesis 落盘 + 轮询拉取 + applyStable + 自动 lifecycle progress）；`operator_ui.html` 按 07 号 IA 实现，1s 轮询 /api/projection；web 层补投影 API/UI 服务/命令字段自动填充/kill latch 自动绑定；八阶段整链路验收（含磁盘日志重放等价断言）`operator_ui_acceptance=passed`；四条既有回归全绿。
- [原型并冻结操作界面信息架构](issues/07-prototype-operator-ui.md) — 冻结 B 分页工作台 IA：六页（总览/持仓挂单/风险与保证金/盈亏/操作台+事实流/命令历史）；总览为精简响应式卡片网格；风险页含保证金缓冲/清算距离/MarginSafetyGates 三档；盈亏页带汇总免责；RiskWarning 统一模态（一次性 RW 编号+后果文案+影响范围）。主源 prototype-operator-ui.html，细节见票。
- [实现 OwnerSession 认证与 RiskWarning 确认后端](issues/06-implement-auth-and-risk-warning.md) — scrypt 口令 + RFC 6238 TOTP（±1 步 + 已消费步重放防护）+ 单一活动限时会话；HTTP 后端仅绑 127.0.0.1，Cookie HttpOnly/SameSite=Strict + 每会话 CSRF 头 + 登录限速；高风险命令（enable_trading/de_risk/stop_keep_positions/resolve_latch）必须持一次性 warning_identity 且载荷精确匹配，确认后签名入队 04 号通道并写 OperatorRecord JSONL；八阶段验收 `owner_session_acceptance=passed`。
- [实现分片稳定日志只读投影](issues/05-implement-read-projection.md) — `control_projection.zig` 经核心新公开入口 `replayForProjection` 复用恢复同一条 SemanticReplay 路径；结构/语义失败一律显式 degraded 且不泄露状态字段；genesis 构造上提为 `applyCanonicalGenesis` 单一事实源；三阶段验收 `control_projection_acceptance=passed`，全量回归 108/108。
- [实现签名命令注入通道](issues/04-implement-command-channel.md) — `control_channel.zig` 信封/HMAC/路由/TCP 拉取/目录排空全落地；`kill_switch` CommandKind + `operator_kill` GateReason（尾部追加，codec 兼容）；Python 签名服务与紧急控制台；91 项 Zig 测试 + 三阶段跨语言验收 `control_plane_channel_acceptance=passed` 全绿。
- [确定 ControlCommand 注入通道与失联降级设计](issues/03-design-command-channel.md) — 主通道 localhost TCP（Python 监听、Zig 宿主代四分片统一拉取、长度前缀帧 + 帧级 HMAC）；校验两层分离（通道层 MAC、业务层归分片 applyCommand 权威裁决，expected_version 由 UI 从投影填入）；失联 = 无新命令、交易面按既有授权继续；紧急 KillSwitch 经投递目录 + 独立控制台脚本（同一信封同一验签）；命令经既有 applyStable 入日志同构重放，唯一核心变更是 kill_switch CommandKind。
- [冻结控制面产品闭环与权威所有权](issues/01-freeze-control-plane-contract.md) — 三句所有权边界（命令产出/会话/只读投影缓存，永不拥有权威状态）；首版命令集为分片现有七种并新增 kill_switch CommandKind（需知会核心波次）；HMAC-SHA256 MAC 作首版签名、生产化升级非对称；五组+一验收矩阵；CONTEXT.md 新增 ControlPlane 词条。
- [研究 Python 标准库控制面技术基础](issues/02-research-python-stdlib-foundations.md) — 研究事实已归档：http.server 需手写 SSE/准确 Content-Length；TOTP 标准库可行（±1 步窗口 + 已消费步重放记录）；本地通道三候选均双侧可行、localhost TCP 成本最低而 UDS 是 Linux 更优解；原生 ES module 单页零构建可行但必须经 HTTP 服务。细节见 [research/01-python-stdlib-foundations.md](research/01-python-stdlib-foundations.md)。

（建图时确定的基线，细节随票关闭逐条补充）

- 目的地为能力波次：可运行最小控制面 + 本地 Web 界面 + 整波自动验收。
- 技术栈：纯 Python 标准库（含标准 TOTP）；UI 为本地 Web 单页。
- ControlCommand 注入采用"控制面只产出、分片进程拉取并在自身日志内应用"的同构模式，
  不直写分片状态。
- UI 数据来自分片稳定日志 tail 重放的只读投影，不向核心在线查询。
- OwnerSession 首版即完整实现口令 + TOTP + 限时会话。
- 与交易核心闭环波次并行，不互相阻塞。

## Not yet specified

暂无；OperatorRecord 存储（JSONL，随 08 号落地）与 UI 刷新机制（1s 轮询）均已定型。

## Out of scope

- DeployRelease / ForwardRollback 操作命令与界面（版本切换留后续票）。
- 生产 Linux systemd 部署、节点代理与发布流水线（独立生产部署波次）。
- 单活热备切换的操作界面。
- 多用户/RBAC：永远只有单一 SystemOwner。
- 研究数据平台与回测报告展示。
- 外部监控/告警渠道的接收端（TelemetryPublish 的下游）。
- 移动端适配。

