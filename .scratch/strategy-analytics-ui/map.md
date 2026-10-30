# 策略分析界面规格

Label: wayfinder:map
Status: closed

## Destination

冻结一份**策略分析界面规格**（Markdown 文档，不含实现）：定义面向 SystemOwner 的本地只读
分析应用的页面信息架构、数据契约（实时投影扩展 + 离线派生数据集两条腿）、按策略/跨账户
归因模型，以及未来实现波次的验收标准草案。覆盖四类展示：多类别策略（CTA、资金费套利、
期权占位）、权威决策链运行日志、跨 ExchangeAccount 聚合、收益图表。实现本身不在本图内。

## Notes

- 领域：量化交易系统（见根目录 CONTEXT.md）；本图消费其 VirtualPortfolio / ExchangeAccount /
  RealizedPnL / ValuationSnapshot / CorrelationIdentity / ResearchDataset 词条。
- 技能：处理任何票前先调 Skill 工具加载 "grilling" 与 "domain-modeling"。
- 既定偏好（建图时经 grilling 敲定）：
  - 目的地是规格而非能力波次；零构建纯标准库前端路线延续；
  - 图表用 vendored 单文件库（uPlot 候选）或内联 SVG；
  - 数据管道混合式：当前快照走现有投影路径扩展字段，时序/归因走日志离线派生数据集；
  - 分析应用与 operator_ui **分离**（独立端口/入口），后者保持窄安全操作台定位；
  - 运行日志首版仅权威决策链（OrderIntent→风控→OrderCommand→Fill，CorrelationIdentity 关联）；
  - 每策略归因首版**零 codec 变更**：策略维度 = VirtualPortfolio × `strategy_activated`
    授权映射（领域默认一 portfolio 一条策略链）；近似失效条件须写入规格；
  - 期权仅作 UI 占位分组，数据恒空；
  - 跨账户维度进数据模型，验收 fixture 先单账户（identity=900）多 VirtualPortfolio。
- 已知代码事实（2026-08 探索）：投影 API 无 PnL/余额/净值字段；RealizedPnL 为重算值非日志
  事件；EconomicFill 不带 strategy_identity；RunArtifact/ResearchDataset 仅词条无代码；
  日志每记录带四组时间戳+presence 位，时间序列完全可重建。

## Frontier

暂无——波次已关闭（5/5 票全部闭合），规格已冻结于 [spec.md](spec.md)。

## Decisions so far

- [关闭策略分析界面地图](issues/05-close-analytics-map.md) — CONTEXT.md 无需改动（round-trip=AverageCost 既有语义的观测输出，快照=DatasetManifest 既有词条，规格细节不入词表）；README 不加章节（只产规格、无可运行能力）；fog 清点留档；实现波次入口条件已声明。
- [冻结策略分析界面规格](issues/04-freeze-analytics-spec.md) — [spec.md](spec.md) v1 冻结：五区 IA + 数据契约摘要 + 唯一核心变更（economics.Projection 减仓观测输出）+ 五项不要求边界带解锁条件 + 七条验收断言草案。
- [设计数据契约：投影扩展与派生数据集](issues/03-design-data-contracts.md) — 六问全按推荐：Zig 探针单次重放吐全部派生（Python 永不解码日志）；round-trip=AverageCost 释放事件；benchmark 用 mark_price 归一化；快照=版本化目录+manifest（DatasetManifest 首落地）；NAV 缺价显式 unknown；K线从 mark_price 聚合。九数据集字段级契约见 [research/data-contracts-v1.md](research/data-contracts-v1.md)。
- [原型并冻结分析界面信息架构](issues/02-prototype-analytics-ia.md) — 冻结 A 版侧栏工作台骨架（四区导航）：总览双栏布局、决策链时间线带环节/状态标签；并入开源面板调研的 8 项必要 UI（绩效卡片组、月度热力图、盈亏直方图、双口径对比、交易透视、K 线回放、回撤区间表、结果管理器新页）；可选 7 项入 fog。原型见 [prototype-analytics-ui.html](prototype-analytics-ui.html)。
- [开源量化面板调研](issues/02-prototype-analytics-ia.md)（支撑研究）— 9 个系统一手来源盘点：FreqUI/jesse/pyfolio 的绩效统计与 tearsheet、nautilus 的 fills 回放、qlib/Lean 双口径对比等；必要/可选/不做三档清单，全文见 [research/02-open-source-analytics-panels.md](research/02-open-source-analytics-panels.md)。
- [图表技术选型研究](issues/01-research-charting-tech.md) — 首推 uPlot 1.6.32（22 KB gzip，MIT，单文件 IIFE/ESM 双形态，回撤一行配置）；兜底 Chart.js UMD；排除 ECharts 与手写 SVG。全文见 [research/01-charting-tech.md](research/01-charting-tech.md)。
- [规格渲染原型·定稿视觉基准](spec.md) — 2026-08-26 经逐屏确认：[prototype-spec-ui.html](prototype-spec-ui.html) 取代早期三变体 [prototype-analytics-ui.html](prototype-analytics-ui.html)；最终 IA（总览无跨账户、决策链 K线顶置双栏、α/β+交易级指标集）已回写 spec §2 与 §0 定稿记录。

## Not yet specified

- 可选 UI 档（来自开源面板调研）：滚动 Sharpe、按小时聚合、跨账户 sunburst 三级筛选、多策略聚合 dashboard、静态 HTML tearsheet 导出、未来函数检测页、风险健康状态条——**留 fog 原因**：基线 UI 尚未实现，增强无从谈起；规格实现后按体验反馈毕业。
- 核心事件契约 v2：给 EconomicFill / external_order_intent 增加 strategy 维度——**留 fog 原因**：领域默认一 portfolio 一条策略链，归因近似未失效。
- 外部行情基准导入（归因页任意 benchmark）——**留 fog 原因**：无对比外部指数的真实需求。
- stale 价格回退展示（NAV 用上次已知价+标注时长）——**留 fog 原因**：等"无法估值"体验反馈。
- 策略内部信号遥测（如 CTA 指标快照）的采集面设计——依赖 StrategyHostControlChannel 扩展决策，且需先回答"私有状态为何要进可观测面"的领域问题。
- 期权策略真实数据接入——依赖核心产品域扩展（现货+永续之外的 Instrument 类型）。
- 多 ExchangeAccount 验收 fixture 与演示——等核心有第二个账户的真实需求。
- 分析结果导出的 DataSensitivity 继承与访问控制——等出现导出场景。
- 实时性升级（WebSocket 推送替代轮询）——单用户本地工具暂无必要，等刷新体验反馈。

## Out of scope

- 分析界面的**实现**与整波自动验收——目的地是规格；实现是未来独立能力波次。
- 期权定价/希腊字母等期权专属分析——核心不支持期权产品（CONTEXT.md 首版仅现货永续）。
- 生产部署资格（TLS、认证强化、多用户）——单用户本地工具前提不变。
- operator_ui 的任何改动——两应用分离已定。
