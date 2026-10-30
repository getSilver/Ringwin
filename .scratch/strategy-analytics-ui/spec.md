# 策略分析界面规格 v1

- 版本：v1（冻结于 2026-08-26）
- 状态：**定稿**（2026-08-26）——IA 经逐屏确认，视觉基准见 [prototype-spec-ui.html](prototype-spec-ui.html)（确定性假数据，仅视觉对齐）
- 来源地图：[策略分析界面规格 Wayfinder 地图](map.md)
- 支撑材料：[IA 原型](prototype-analytics-ui.html)（A/B/C 三变体，已被定稿原型取代） · [数据契约草稿](research/data-contracts-v1.md) · [图表选型](research/01-charting-tech.md) · [开源面板调研](research/02-open-source-analytics-panels.md)
- 性质：**规格冻结，非实现**。实现是未来独立能力波次。

## 0. 定稿 IA 关键修订（相对初版）

逐屏确认后的最终布局，spec §2 已含，此汇总便于实现波次对照：

1. **总览**：双栏左 2fr 含全部 KPI 卡片（分风险调整行 + 交易级行）、权益/回撤双图、回撤区间 Top-N；右 1fr 仅**策略组表**——跨账户汇总不进总览（独立导航区）。
2. **决策链日志**：顶部全宽 K 线回放 + fills 叠加；下部双栏左=近期风控拒绝表、右= intent#42 时间线。
3. **指标集**：在 Sharpe/Sortino 外补 Alpha(年化)/Beta（CAPM，基准=BTC 归一化）、Calmar、年化波动率；交易级补胜率/盈亏比/期望值/最大连亏，分两行展示避免拥挤。
4. 图表技术、数据契约、归因口径、降级行为均与 §2–§4 一致。

---

## 1. 产品定位与边界

面向 SystemOwner 的**本地只读策略分析应用**：单用户、绑 127.0.0.1、零构建前端。
与 operator_ui 操作台完全分离（独立端口/入口）——操作台是高风险命令入口，
本应用是纯只读消费端，二者不共享攻击面。不提供任何下单、撤单、配置修改能力。

## 2. 页面信息架构（已冻结）

骨架：**侧栏工作台**——左侧固定导航五区，单区视图切换。

| 导航区 | 内容 |
|---|---|
| **总览** | 双栏：左 2fr = KPI 行（净值/当日/近30日/最大回撤/费用 + 风险调整行：Sharpe/Sortino/Calmar/Alpha(年化)/Beta/年化波动 + 交易级行：笔数/胜率/盈亏比(均盈均亏)/profit factor/期望值/最大连亏/CAGR 卡片组）+ 权益曲线/回撤 underwater 双图 + 回撤区间表 top-N；右 1fr = 策略组运行状态表（options 占位灰组）。跨账户汇总不进总览，仅独立导航区（2026-08-26 修订） |
| **收益归因** | 按策略堆叠累计盈亏面积图 + 资金费贡献副图；扣费前后双口径 + benchmark 对比线；月度热力图 + 年度柱状图；逐笔盈亏直方图 + 按序条形图；交易透视表（策略×交易对×多空）；归因口径标注（portfolio×授权映射及失效条件） |
| **决策链日志** | 顶部全宽：fills 叠加 K 线回放（mark_price 聚合，1m/5m/1h 可选）；下部双栏：左 = 近期风控拒绝表（CanonicalRejectReason 分类），右 = OrderIntent 展开的垂直时间线（环节+状态标签）（2026-08-26 修订布局） |
| **跨账户汇总** | 按 ExchangeAccount 分组的 VirtualPortfolio 权益表（数据模型含账户维度，首版单账户 fixture） |
| **结果管理** | 分析快照列表：manifest 元信息、人工备注、两两对比入口 |

通用规则：策略类别为通用枚举（cta/funding_arb/options…），options 为灰色虚线
占位组显示"占位 · 无数据"；NAV 缺价显示"无法估值"，禁止显示 0 或 stale 价。

## 3. 技术约束

- **图表**：uPlot 1.6.32 vendored 单文件（IIFE 全局引入，22 KB gzip，MIT）；堆叠图需预累加数据；兜底 Chart.js UMD。
- **前端**：零构建纯静态 HTML/JS；服务端预聚合，浏览器不做重计算。
- **后端编排**：Python 标准库（沿用 owner_session/control_plane_web 的既有模式），仅做探针调用、快照落盘、静态文件与 JSON 服务。

## 4. 数据契约（v1 摘要，字段级见契约文档）

### 4.1 单一计算路径

全部数据由**扩展后的 Zig 重放探针**在一次 SemanticReplay 中产出；Python 永不解码
二进制日志。探针输出 = 实时投影 JSON + 派生数据集 JSON。

### 4.2 腿 A · 实时投影扩展

ShardView 新增：`realized_pnl_micros` / `unrealized_pnl_micros` / `cash_usdt_micros`
/ `fees_paid_micros` / `nav_usdt_micros|null` / `valuation:"ok"|"unknown"` /
`strategy_groups[]`。全部为 shard 重算值透出，不引入第二计算路径。

### 4.3 腿 B · 九个派生数据集

DS1 权益序列 · DS2 回撤区间 · DS3 round-trips · DS4 资金费序列 · DS5 周期收益 ·
DS6 绩效指标（Sharpe/Sortino 年化系数 √365 写入生成规则身份）· DS7 OHLC bars
（mark_price 聚合，bar 带 fill_count）· DS8 决策链关联 · DS9 双口径+基准
（mark_price 归一化权益线）。

统一文件头 `{schema, cutoff_ns, source_cursor:{target_identity, last_sequence,
journal_content_hash}}`；经济序列时间基准 source_time 优先、到达分析用 receive_time。

### 4.4 归因模型

每策略 ≈ 每 VirtualPortfolio × `strategy_activated` 授权映射（领域默认一条策略链
一个 portfolio）。**失效条件**：一个 portfolio 运行多条策略链时，归因视图必须显式
降级标注"混合归属"，不得静默拆分。

### 4.5 快照存储

```
snapshots/<UTC时间戳>-<slug>/
  manifest.json    # schema 版本集、生成器版本、各数据集内容哈希、来源游标、备注
  ds1.json … ds9.json
  projection.json
```

## 5. 核心依赖与边界

本规格**要求**的核心变更（唯一一项）：economics.Projection 在减仓结算处增加观测
输出（释放数量、order 归属、结算前均价），支撑 DS3 round-trips——只加观测输出，
不改权威状态机与事件 codec。

本规格**明确不要求**的：

| 边界 | 解锁条件 |
|---|---|
| 零 codec 变更（EconomicFill 不加 strategy 字段） | 一个 portfolio 运行多策略链的真实需求 |
| 期权仅 UI 占位 | 核心产品域扩展至现货永续之外 |
| 单 ExchangeAccount fixture | 核心出现第二个真实账户 |
| 无外部行情导入 | 出现对比外部指数的需求 |
| 无 stale 价格回退展示 | "无法估值"体验反馈驱动 |

## 6. 未来实现波次的验收标准草案

失败即停单入口（沿用 `tools\verify-*.ps1` 惯例），至少断言：

1. **派生幂等**：同一 journal 输入跑两遍探针，九个数据集逐字节一致。
2. **投影一致**：扩展字段与直接 SemanticReplay 重算结果逐字段一致（复用既有
   重放对账断言模式）。
3. **决策链完整性**：DS8 中每个 intent 要么有完整关联链，要么有显式 rejection
   记录；无悬空引用。
4. **round-trip 守恒**：DS3 已实现盈亏之和 == shard `realized_pnl_micros`。
5. **快照复现**：任一 manifest 凭来源游标重放日志可重建全部数据集且哈希一致。
6. **降级行为**：缺 mark_price 时 `valuation:"unknown"` 且 UI 渲染"无法估值"；
   多策略共享 portfolio 时归因页出现"混合归属"标注。
7. **既有回归全绿**：控制面波次四条验收 + zig test 不回归。
