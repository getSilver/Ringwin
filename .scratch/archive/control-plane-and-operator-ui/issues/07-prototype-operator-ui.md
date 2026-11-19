# 原型并冻结操作界面信息架构

Type: prototype
Status: closed
Resolution: IA 已冻结；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 05, 06
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

用最少页面清晰展示 OperationalMode、EffectiveTradingAuthority、SafetyGate、持仓挂单、
对账差异及 LifecycleOperation，并安全承载启停、撤单、减仓与应急确认？

## Answer

SystemOwner 经三轮交互反馈后冻结如下 IA（2026-08-23）。
主源: [prototype-operator-ui.html](prototype-operator-ui.html)（本分支 .scratch 内，假数据可交互）。

**骨架：B 分页工作台**
- 左侧固定侧边栏（210px，深色，含会话标识），右侧主区按页切换。
- 深色 monospace 主题，语义色 token：ok/warn/bad。

**六个页面（顺序即导航序）**
1. **总览** — 响应式网格卡片（`repeat(auto-fill,minmax(380px,1fr))`，row-gap 16px）。
   卡片刻意精简为一行关键指标：模式 pill（TRADING✓授权 / 无授权 / KILL-锁存 n /
   DRAINING）+ 挂单数、仓位、保证金缓冲、清算距离 bps、未实现盈亏五个数字 +
   BREAK/仅减仓异常 pill；底部灰字提示详情在各分页。卡片下方整宽 SafetyGates
   面板（原因/类型/开闭表）。
2. **持仓挂单** — 全部挂单表格（分片/品种/方向/数量/价格/状态）。
3. **风险与保证金** — 每分片一卡：标记价格、组合保证金权益、初始/维持保证金、
   **保证金缓冲**（加粗）、**清算距离 ticks+bps**（加粗）、Venue 净保证金、
   账户净额收益、风险租约余额、费用缓冲；下方 MarginSafetyGates 三档状态
   （OpeningGate/WarningGate/KillGate → 通过/预警/触发 pill）。词汇对齐 CONTEXT.md。
4. **盈亏** — 每分片未实现盈亏（红绿着色）、今日已实现、OpenCost、NAV、今日手续费/
   返佣/资金费；底部合计行必须带"仅为展示汇总，不构成跨分片经济事实"免责声明。
5. **操作台** — 每分片命令按钮组（EnableTrading*/Pause/CancelOpenOrders/DeRisk→0*/
   ResolveLatch*/KillSwitch*，\*=高危需确认）；下方并入事实流面板（C 方案胜出部分，
   最新在前，operator_action 实时插入）。
6. **命令历史** — OperatorRecord 表（时间/操作者/命令/目标/警示编号）。

**RiskWarning 确认流（全部页面共用同一模态）**
弹窗内容：对象 shard-n、操作名、警示编号 RW-n、当前状态 pill 行（含挂单/仓位/缓冲）、
后果一句话（每 kind 固定文案）、影响范围 pre 块（DecisionDomain 范围 + 写入日志可重放）。
按钮：取消 | "我已理解，确认执行"。确认 → ControlCommand 入队 toast + OperatorRecord
新增 + 事实流插入。低风险命令（Pause/CancelOpenOrders）不弹窗直接入队。

**08 号实现约束**
- 数据形状对齐 `control_projection.zig` ShardView JSON + 保证金/PnL 投影扩展。
- 高危按钮集合与后端 HIGH_RISK_KINDS 一致；warning_identity 由 06 号后端签发。
- 数据刷新机制（轮询 vs SSE）仍留 08 号决定（地图 fog 保留该项）。

## Comments

- 2026-08-23：v1 三变体（A 单屏/B 工作台/C 队列流）→ SystemOwner 选 B 并要求合并 C
  事实流、新增保证金/盈亏视图；v2 落地；随后简化总览卡片、改响应式多栏网格、补行间距，
  SystemOwner 确认冻结。
