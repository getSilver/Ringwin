# 原型并冻结分析界面信息架构

Type: prototype
Status: closed
Assignee: ox-alpha (本会话)
Label: wayfinder:prototype
Blocked by: 01

## Question

做一份低保真单页 HTML 原型（静态假数据即可，图表可用占位或按 01 号研究结论的
真实库），让 SystemOwner 亲眼确认后冻结 IA。必须覆盖四类展示的最小布局：

1. **总览**：账户/投资组合权益曲线 + 当前净值快照；策略分组入口（cta /
   funding_arb / options 占位灰组）。
2. **收益归因**：按 VirtualPortfolio（≈策略）分解的累计盈亏堆叠图、回撤曲线、
   资金费贡献单独一条线。
3. **决策链日志**：选一条 OrderIntent 展开其 CorrelationIdentity 关联视图
   （intent → 风控拒绝/接受 → command → fill），含时间轴与拒绝原因。
4. **跨账户汇总**：单页表格按 ExchangeAccount 分组列出各 VirtualPortfolio
   权益与当日变动。

原型要回答的取舍：导航形态（侧栏 vs 顶栏）、时间范围选择器放哪、决策链用
时间线还是表格式、占位期权组如何呈现"无数据"而不像坏了。

产出：`prototype-analytics-ui.html` 放本地图目录根。冻结结论写入 Answer。

## Answer

已冻结（2026-08-26）。原型：[prototype-analytics-ui.html](../prototype-analytics-ui.html)（uPlot 1.6.32 本地文件，确定性假数据，`?variant=` 三变体可切换）。

**SystemOwner 拍板：A 版侧栏工作台为骨架**，含两处修订：
1. 决策链时间线每条事件补齐**环节标签**（Intent/风控/命令/成交/对账，灰 pill）与**状态标签**（通过/接受/已发送/部分成交/终态确认，绿红 pill），信息量对齐 B 版表格；
2. 总览采用 B 版**双栏布局**：左 2fr 权益曲线+回撤副图+KPI 行+策略组 pill，右 1fr 跨账户汇总表。

**冻结 IA**
- 骨架：左侧固定导航四区（总览/收益归因/决策链日志/跨账户），单区视图切换；分析应用与 operator_ui 完全分离。
- 总览 = 双栏（如上）；策略组以 pill 呈现运行状态与净值，options 为灰色虚线占位组。
- 收益归因 = 按策略堆叠累计盈亏面积图 + 资金费贡献独立副图；标注归因口径（portfolio×授权映射）。
- 决策链日志 = 垂直时间线（带环节/状态）+ 近期风控拒绝表（CanonicalRejectReason 分类）。
- 跨账户 = 按 ExchangeAccount 分组的 VirtualPortfolio 表格。

**并入的必要 UI（来自 [开源面板调研](../research/02-open-source-analytics-panels.md)，SystemOwner 指示"加入必要的 UI"）**
映射到冻结页面结构：
- 总览：绩效统计卡片组扩充（Sharpe/Sortino/win rate/profit factor/max DD/CAGR——jesse、FreqUI、pyfolio 实践）；回撤区间表（top 5 drawdown periods + underwater 曲线已有雏形）。
- 收益归因：月度收益热力图 + 年度柱状图（jesse/nautilus）；逐笔盈亏直方图 + 按序条形图（FreqUI）；扣费前后双口径 + benchmark 对比线（qlib/Lean）；交易透视表（策略×交易对×多空分组——pyfolio round-trip）。
- 决策链日志：fills 叠加 K 线回放视图（nautilus bars_with_fills/jesse；K 线从日志 mark_price/l2 重建）。
- 新增第五导航区「结果管理」：多次分析快照的备注与两两对比入口（FreqUI BacktestResultSelect 实践）。

可选档（滚动 Sharpe、跨账户 sunburst、tearsheet 导出等 7 项）记入地图 fog，不在本版范围。
