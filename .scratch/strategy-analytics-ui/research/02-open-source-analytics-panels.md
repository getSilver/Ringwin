# 开源量化系统分析面板调研

调研目标：知名开源量化系统的策略分析面板/前端展示哪些 UI 元素，为我们的单用户本地只读策略分析工具（权益曲线、按策略归因、决策链日志、跨账户汇总）找出值得补充的必要 UI。

方法：逐系统查 GitHub 仓库 README / docs 目录 / 官方文档站 / 前端源码目录。每个论断附来源链接。

---

## 各系统盘点

### 1. nautilus_trader（nautechsystems/nautilus_trader）

**官方 UI 立场**：v2 起明确"UI dashboards or frontends 不在项目范围内"，专注核心引擎（[ROADMAP.md](https://github.com/nautechsystems/nautilus_trader/blob/develop/ROADMAP.md)）。历史上曾有内置 Node/React Web UI，后已从包中移除（检查 v1.120–v1.193 各 tag 的 `nautilus_trader/` 目录均无 `ui/`，见 [repo tags](https://github.com/nautechsystems/nautilus_trader/tags)）。社区因此出现了多个第三方 React/FastAPI 管理界面（如 [Nautilus-Web-Interface](https://github.com/Black101081/Nautilus-Web-Interface)：Dashboard/Strategies/Orders/Positions/Risk/Market Data/Performance/Alerts/Backtesting 九个页面；[nautilus-trader-admin](https://github.com/Black101081/nautilus-trader-admin)：19 个管理页）。

**官方分析产物是 HTML Tearsheet**（非在线面板），`nautilus_trader[visualization]` extra，基于 Plotly（[docs/concepts/visualization.md](https://github.com/nautechsystems/nautilus_trader/blob/develop/docs/concepts/visualization.md)、源码 [python/nautilus_trader/analysis/tearsheet.py](https://github.com/nautechsystems/nautilus_trader/blob/develop/python/nautilus_trader/analysis/tearsheet.py)）：

- 内置图表：`run_info`（Run 元数据 + 各币种期初/期末账户余额表）、`stats_table`（分 PnL / Returns / General 三段绩效统计）、`equity`（累计收益曲线，可叠 benchmark）、`drawdown`（回撤面积图）、`monthly_returns` 热力图、`distribution`（收益直方图）、`rolling_sharpe`（60 日滚动 Sharpe）、`yearly_returns` 柱状图、`bars_with_fills`（K 线上叠加成交 fill 标记，用于执行分析）
- 统计指标分组：PnL Statistics（Total PnL、win rate、profit factor 等）、Returns Statistics（Sharpe、Sortino、Max Drawdown 等）、General Statistics（总交易数、平均持仓时长等）
- 多币种按币种分别统计或过滤；支持 benchmark 叠加；主题/布局/自定义图表注册机制
- 生态参考：Helm 前端把 "AI Decision Feed"（决策理由卡片 + 置信度 + 已实现 PnL 跟踪）作为一等公民（[sh1ftmaker/helm README](https://github.com/sh1ftmaker/helm)）

### 2. freqtrade + FreqUI（freqtrade/frequi）—— 页面清单最成熟

FreqUI 是 Vue3 前端，页面清单直接来自源码 `src/pages/`（[GitHub API 列目录](https://github.com/freqtrade/frequi/tree/develop/src/pages)）：

| 页面文件 | 内容 |
| --- | --- |
| `dashboard.vue` | 多 bot 总览：每日/累计利润图、随时间推移的余额曲线（含未实现盈亏与出入金）（[docs.freqtrade.io/en/stable/freq-ui/](https://docs.freqtrade.io/en/stable/freq-ui/)） |
| `trade.vue` | 实时交易视图：当前持仓、挂单、K 线 + 指标 + 买卖点叠加 |
| `graph.vue` | 图表视图（Plot Configurator 可配置多套指标绘图方案并切换） |
| `backtest.vue` | 回测：运行回测、加载历史结果、结果间对比 |
| `balance.vue` | 多交易所资产余额汇总 |
| `pairlist.vue` / `pairlist_config.vue` | 白名单/黑名单交易对管理 |
| `open_trades.vue`、`trade_history.vue` | 未平仓交易 / 成交历史表 |
| `logs.vue` | 日志流 |
| `lookahead_analysis.vue`、`recursive_analysis.vue` | 未来函数检测、递归偏差分析专用页 |
| `download_data.vue`、`settings.vue`、`login.vue` | 数据下载 / 设置 / 登录 |

回测分析细节（[DeepWiki: Backtesting & Analysis](https://deepwiki.com/freqtrade/frequi/5.2-backtesting-and-analysis)，源自 `src/types/backtest.ts` 与图表组件）：
- 指标：`profit_total/profit_total_abs/profit_mean`、`profit_factor`、`max_drawdown/max_drawdown_abs`、`sharpe`、`sortino`、`calmar`、`total_trades/wins/losses/winrate`、`winning_days/losing_days`
- 专属图表组件：`CumProfitChart`（阶梯累计利润 + 含未实现盈亏的投影虚线 + 多 bot 聚合 + 缩放）、`ProfitDistributionChart`（利润率直方图，可调 bin 数）、`TradesLogChart`（逐笔盈亏条形图，默认显示最近 50 笔可缩放）、`HourlyChart`（按小时聚合的利润与交易次数双轴图）
- 结果管理：多次回测结果的选择器、快速对比预览、备注（notes）内联编辑
- 按 Pair 分组的结果表：每对 `profit_total/trades/wins/losses/winrate`

### 3. jesse-ai/jesse

自托管 GUI Dashboard（Next.js 风格 web 界面）+ 研究 API（[docs.jesse.trade](https://docs.jesse.trade/)）：
- 回测结果页是一张完整指标表（[docs/backtest/results](https://docs.jesse.trade/docs/backtest/results)）：总平仓笔数、净利/百分比、期初期末余额、未平仓、总手续费、Max Drawdown、最长水下周期、Annual Return、Expectancy（绝对+百分比）、Avg Win/Loss 与比值、Win-rate（含多空拆分）、平均持仓时长（赢利/亏损分开）、Sharpe、Calmar、Sortino、Omega、连胜/连败、最大单笔赢/亏
- 图表集（[docs/backtest](https://docs.jesse.trade/docs/backtest/)）：累计收益 vs benchmark、回撤区间、underwater plot、月度收益热力图、逐笔 P&L 分布；交互式 K 线图可查看每笔进出场（[docs/charts/interactive-charts](https://docs.jesse.trade/docs/charts/interactive-charts)）
- 全部指标 API 清单见 [docs/strategies/api.html](https://docs.jesse.trade/docs/strategies/api.html)（含 gross_profit/gross_loss、expected_net_profit_every_100_trades、current_streak 等）
- 特色研究功能：Monte Carlo 分析、规则显著性检验（bootstrap）、参数优化训练/测试分离（[首页特性卡](https://docs.jesse.trade/)）；导出 CSV/JSON/Pine Script；Benchmark 页支持多配置并行对比

### 4. vnpy / VeighNa 系列（中文社区主流）

桌面 Qt GUI（PyQtGraph），不是 web（[vnpy README](https://github.com/vnpy/vnpy)）：`from vnpy.trader.ui import MainWindow, create_qapp` 启动主窗口。
- **VeighNa Trader 主界面**：行情、K线图表（chart_wizard）、委托、成交、持仓、资金、日志等标签页（各 app 共享主窗口）
- **cta_backtester**：图形界面直接做 CTA 策略回测分析与参数优化，无需 Jupyter（README 功能列表第 3.2 条）
- **portfolio_manager（vnpy_portfoliomanager）**：以独立策略交易组合（子账户）为单位，提供委托成交记录管理、仓位自动跟踪、每日盈亏实时统计——即"按策略归因 + 组合汇总"的最简实现
- **risk_manager**：流控/下单量/活跃委托/撤单总数的前端风控统计
- **data_manager**：树形目录查看数据库数据概况与字段细节
- 4.0 新增 vnpy.alpha 投研 lab，notebook 内置可视化评估策略表现与模型效果（README "AI-Powered" 节）

### 5. hummingbot/hummingbot + dashboard

Streamlit Dashboard，文档侧边栏给出全部页面（[hummingbot.org/dashboard/](https://hummingbot.org/dashboard/)）：Credentials、Portfolio、Configuring Strategies、Backtesting、Deploying Instances、Managing Instances。注意官方已宣布不再积极维护，推荐继任者 Condor。

Portfolio 页细节（[hummingbot.org/dashboard/portfolio/](https://hummingbot.org/dashboard/portfolio/)）——对我们跨账户汇总最有参考价值：
- **Account / Exchange / Token 三级多选过滤器**（可选多个账户合并视图）
- **总余额(USD) 卡片** + **sunburst 旭日图**按 account → exchange → token 层级展示配置占比
- 明细表：exchange、token、units、price、value、可用数量
- **组合总值随时间折线图** + 单 token 价值随时间折线图

其他页：Bot Orchestration（部署/管理多实例、实时性能监控）、基于 Optuna 的策略回测与优化（[dashboard README](https://github.com/hummingbot/dashboard)）。

### 6. Drakkar-Software/OctoBot

自带 web 界面（Flask/Tornado）+ 移动端 + Telegram（[OctoBot README](https://github.com/Drakkar-Software/OctoBot)）：
- 主 dashboard：组合价值曲线、历史利润（profits）、近期活动（recent activities）、持仓内容
- 回测报告页：以初始组合出发的策略历史表现指标集（截图 `assets/backtesting_report.jpg`）
- 新 beta（node mode）：多组合（multi-portfolio）分析与自动化统一 dashboard，钱包、自动化、多策略集中管理
- 配置向导式策略配置（traded markets/exchanges）、paper trading、TradingView/AI 连接器

### 7. microsoft/qlib

无 web 面板，提供 notebook 内 plotly 报告库 `qlib.contrib.report`（[docs/component/report.rst](https://github.com/microsoft/qlib/blob/master/docs/component/report.rst)）：
- `analysis_position.report_graph`：7 行子图——cum return w/o cost、w cost、benchmark、超额收益（CAR）w/o & w cost、turnover、对应 max drawdown 阴影区
- `score_ic_graph`：IC/Rank IC 时序；`cumulative_return_graph`：buy/sell/hold 分解累计收益 + 权重；`rank_label_graph`
- `risk_analysis_graph`：excess return w/o & w cost 的 annualized_return / information_ratio / max_drawdown / std 四联图 + 月度分组版本
- `analysis_model.model_performance_graph`：分层（Group1–Group5）累计收益、long-short/long-average、IC 分布 Q-Q、自相关（估算换手）
- 关键思想：**所有收益都同时给 with-cost 和 without-cost 两套**，且始终相对 benchmark

### 8. backtrader 与 zipline/pyfolio

- backtrader：matplotlib 单图绘制数据/指标/Observer（[plotting docs](https://www.backtrader.com/docu/plotting/plotting/)）。默认三个 Observer：`CashValue`（现金与组合价值时序）、`Trade`（每笔平仓盈亏）、`BuySell`（价格图上的买卖标记）。Analyzers 提供指标（含 PyFolio 集成，[analyzers-pyfolio](https://www.backtrader.com/docu/analyzers/pyfolio/)），Observers-Benchmark 提供相对基准对比（[observer-benchmark](https://www.backtrader.com/docu/observers-and-statistics/observers-and-statistics/)）
- zipline 本身只有 result DataFrame；可视化事实标准是 pyfolio tearsheets（[pyfolio tears.py](https://github.com/quantopian/pyfolio/blob/master/pyfolio/tears.py)、[zipline 示例](https://pyfolio.ml4trading.io/notebooks/zipline_algo_example.html)）：
  - returns tear sheet：滚动收益锥、rolling beta/sharpe、drawdown periods 表（top10，含 peak/valley/recovery/duration）、underwater、月度/年度收益热力图、收益分位数
  - position tear sheet：gross leverage、 exposures、 top holdings
  - txn tear sheet：换手率、日成交量直方图
  - round-trip tear sheet：按标的/多空分组的 profit factor、胜率、持仓时长分布、"利润归因到标的"（show_profit_attribution）
  - 指标大表：annual return/volatility、Sharpe、Calmar、Sortino、Omega、Skew、Kurtosis、Tail ratio、VaR、Gross leverage、Daily turnover；in-sample vs out-of-sample 分列

### 9. QuantConnect/Lean

开源 `Report/` 目录生成静态 HTML/PDF 投资级报告（[QuantConnect/Lean/tree/master/Report](https://github.com/QuantConnect/Lean/tree/master/Report)、[lean.io Report API](https://www.lean.io/docs/v2/lean-engine/class-reference/py/QuantConnect/Report/Report/)、[CLI reports 文档](https://www.quantconnect.com/docs/v2/lean-cli/reports)）：
- 内容：KPI 卡片（`{{$KPI-SHARPE}}` 等模板键）、cumulative returns（回测 vs benchmark vs live 叠加）、daily returns 条形图、returns per trade/day/month/year 直方图、crisis plots（危机事件期表现）、策略参数表
- 特色：同一张报告里 **backtest 与 live 结果并列对比**（同图双色），median 标线
- 自定义：替换 template.html/report.css 即可改版式

---

## 共性元素归纳

几乎所有系统的分析面都收敛于以下元素：

1. **权益/累计收益曲线**（必配 benchmark 或 buy-and-hold 对比）——jesse、nautilus tearsheet、qlib、Lean、backtrader CashValue、FreqUI CumProfitChart、Hummingbot portfolio evolution
2. **回撤表达两种形态**：underwater 曲线 + top-N 回撤区间表（peak/valley/recovery/duration）——pyfolio、jesse、nautilus drawdown chart
3. **绩效统计卡片/表格**，普遍包含：total return、CAGR/annual return、Sharpe、Sortino、Calmar、win rate、profit factor、expectancy、max DD、avg win/loss 比、连续盈亏、平均持仓时长；qlib/Lean 额外强调 with/without cost 双口径与 information ratio
4. **收益分布与时间切片**：逐笔盈亏直方图（FreqUI TradesLogChart/DistributionChart、Lean per-trade histogram、nautilus distribution）、月度热力图 + 年度柱状图（jesse、nautilus、pyfolio）、按小时聚合（FreqUI HourlyChart）
5. **交易明细表 + K 线买卖点叠加**：几乎每家都有 trades 表；nautilus bars_with_fills、jesse interactive charts、FreqUI trade view 把成交画回 K 线
6. **归因维度**：按标的/pair（FreqUI pair 表、pyfolio profit attribution by symbol/sector、qlib cumulative_return buy/sell/hold 分解）、按多空方向（jesse win-rate longs/shorts、pyfolio long/short 列）、按模型信号分层（qlib Group1–5）
7. **多实例/多账户聚合**：FreqUI dashboard 多 bot 聚合切换、Hummingbot Portfolio 页 account×exchange×token 三级筛选 + sunburst、vnpy portfolio_manager 子账户日度盈亏
8. **结果管理与对比**：FreqUI 回测结果选择器 + 对比 + notes；jesse Benchmark 并行对比；Lean backtest vs live 同图
9. **日志流页面**（FreqUI logs.vue）与**健康/风控状态**（nautilus 第三方面板 Risk 页、vnpy risk_manager）在"实盘监控型"前端常见，纯分析工具较少
10. **静态报告输出**是一条平行路线：HTML tearsheet 归档/分享（nautilus、Lean），而非常驻服务

---

## 对我们的补充建议（必要 / 可选 / 不做）

我们已有：权益曲线、按策略归因、决策链日志、跨账户汇总。以下按"单用户本地只读分析工具"定位分级。

### 必要（建议补充）

1. **绩效统计卡片组** —— 来源：jesse 指标表 / FreqUI backtest / pyfolio。至少：net profit%、CAGR、max DD、Sharpe、Sortino、win rate、profit factor、expectancy、avg win/loss 比、总手续费。这是所有系统的公共底座，缺它权益曲线无法解读。
2. **回撤区间表 + underwater 曲线** —— 来源：pyfolio drawdown periods（peak/valley/recovery/duration）、jesse underwater plot。比单纯最大回撤数字有用得多。
3. **月度收益热力图 + 年度收益柱状图** —— 来源：jesse、nautilus monthly_returns heatmap、pyfolio。本地工具里信息密度最高的单图。
4. **逐笔交易盈亏分布直方图 + 按序号盈亏条形图** —— 来源：FreqUI ProfitDistributionChart / TradesLogChart。识别"靠少数几笔暴利"型策略。
5. **成交回放叠加 K 线（fills on candles）** —— 来源：nautilus `bars_with_fills`、jesse interactive charts、backtrader BuySell observer。这是审计决策链最直观的入口：点击某笔交易 → 跳到该 K 线上下文。
6. **with-cost / without-cost 与 benchmark 相对收益双口径** —— 来源：qlib report_graph（CAR、w/wo cost、mdd 阴影）、Lean benchmark overlay。费用归因对我们的决策链审计直接相关。
7. **交易列表的多维分组透视（按策略 × 交易对 × 多空方向）** —— 来源：pyfolio round-trip 表（All/Long/Short 三列）、FreqUI pair 表、jesse win-rate longs/shorts。这正是"按策略归因"的表格形态。
8. **回测/会话结果管理器（列表 + 备注 + 对比）** —— 来源：FreqUI BacktestResultSelect（notes 内联编辑、对比预览）。本地只读工具也需要能并排两次 run。

### 可选（有余力再做）

9. **滚动 Sharpe / rolling 指标曲线** —— 来源：nautilus rolling_sharpe、pyfolio rolling sharpe/beta。判断绩效稳定性。
10. **按小时/星期聚合的表现图** —— 来源：FreqUI HourlyChart。加密 24h 市场尤其有意义。
11. **跨账户 sunburst/层级占比图 + 账户×交易所×资产三级筛选** —— 来源：Hummingbot Portfolio 页。我们的跨账户汇总已有表格的话，这是增强可视化。
12. **多 bot/多策略聚合切换的总览 dashboard** —— 来源：FreqUI dashboard（多 bot 聚合 + 含未实现盈亏的余额曲线）。若策略数增多再上。
13. **静态 HTML 报告导出** —— 来源：nautilus create_tearsheet、Lean lean report。"一键导出一份可归档的 HTML"对单人工具成本低价值高。
14. **未来函数/递归偏差检测页** —— 来源：FreqUI lookahead_analysis.vue / recursive_analysis.vue。有回测引擎时才值得。
15. **风险/健康状态条**（行情健康、凭证状态）—— 来源：nautilus 第三方面板 Risk 页、vnpy risk_manager。只在接实盘监控时有意义。

### 不做

16. **登录/多用户权限/凭证管理页** —— Hummingbot Credentials 页、FreqUI login.vue、第三 nautilus 面板的 API key auth：企业级多用户功能，与单用户本地只读定位冲突。
17. **实盘下单/启停 bot 的控制面板** —— FreqUI trade view 的 force entry/exit、Hummingbot Deploy/Instances 页、OctoBot 自动化配置：我们是只读分析工具。
18. **数据下载/白名单管理/参数优化器 UI** —— FreqUI download_data.vue、pairlist_config.vue、Hummingbot Optuna 优化页：属于生产链路，不属于分析面。
19. **移动端/Telegram 通道** —— OctoBot mobile/Telegram：超出本地 web 工具范围。
20. **因子 IC/分层回测（qlib model_performance 类）** —— 仅当引入 ML 因子模型才有意义，当前领域语言中无此需求。

---

## 主要来源索引

- NautilusTrader: https://github.com/nautechsystems/nautilus_trader/blob/develop/ROADMAP.md · https://github.com/nautechsystems/nautilus_trader/blob/develop/docs/concepts/visualization.md · https://github.com/Black101081/Nautilus-Web-Interface · https://github.com/sh1ftmaker/helm
- freqtrade/FreqUI: https://docs.freqtrade.io/en/stable/freq-ui/ · https://github.com/freqtrade/frequi/tree/develop/src/pages · https://deepwiki.com/freqtrade/frequi/5.2-backtesting-and-analysis
- Jesse: https://docs.jesse.trade/docs/backtest/results · https://docs.jesse.trade/docs/backtest/ · https://docs.jesse.trade/docs/strategies/api.html
- vnpy/VeighNa: https://github.com/vnpy/vnpy （README 功能列表、MainWindow 示例）
- Hummingbot: https://hummingbot.org/dashboard/ · https://hummingbot.org/dashboard/portfolio/ · https://github.com/hummingbot/dashboard
- OctoBot: https://github.com/Drakkar-Software/OctoBot
- Qlib: https://github.com/microsoft/qlib/blob/master/docs/component/report.rst
- backtrader: https://www.backtrader.com/docu/plotting/plotting/
- pyfolio/zipline: https://github.com/quantopian/pyfolio/blob/master/pyfolio/tears.py · https://pyfolio.ml4trading.io/notebooks/zipline_algo_example.html
- QuantConnect Lean: https://github.com/QuantConnect/Lean/tree/master/Report · https://www.quantconnect.com/docs/v2/lean-cli/reports
