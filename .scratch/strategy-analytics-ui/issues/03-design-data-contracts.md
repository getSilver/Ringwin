# 设计数据契约：投影扩展与派生数据集

Type: grilling
Status: closed
Assignee: ox-alpha (本会话)
Label: wayfinder:grilling

## Question

规格的数据面两条腿各需要一份 v1 契约，本票经 grilling 敲定字段级设计：

**A. 实时投影扩展**（现有 `control_projection.zig` ShardView 加什么）：
- 候选字段：realized/unrealized PnL、现金余额、费用累计、净值（需 ReportingAsset
  价格路由——fixture 无健康价格源时如何显式呈现 Unknown）。
- 约束：只读投影不得引入第二计算路径——PnL 从 shard 重算结果透出即可。

**B. 离线派生数据集 v1 schema**（从分片日志确定性生成的分析数据）：
- 数据集清单候选：权益时间序列、按 portfolio 的已实现盈亏流水、资金费结算序列、
  决策链关联表（CorrelationIdentity → 各环节事件引用）、跨账户汇总快照。
- 每个数据集需定：主键、时间基准（wall_time vs source_time 的选择规则）、
  KnowledgeCutoff 边界、生成规则身份（TransformationManifest 词条的落地方向）。
- 派生管道宿主形态：Python 读 journal？复用 Zig 探针输出中间 JSON？——给一个
  推荐并说明与"单一事实源"原则的一致性。

**C. 归因映射**：portfolio ≈ strategy 近似的具体实现——`strategy_activated`
授权事实如何映射到 portfolio 维度；近似失效（一 portfolio 多策略）时的显式
降级行为。

产出为 Answer 内的字段表格 + 一份 `research/data-contracts-v1.md` 草稿。

## Answer

已敲定（2026-08-26），六问全部按推荐，字段级契约见 [research/data-contracts-v1.md](../research/data-contracts-v1.md)。决策摘要：

**A. 投影扩展**：ShardView 增加 realized/unrealized PnL、现金、费用累计、NAV（`valuation:"unknown"` 时显式 null，UI 显示"无法估值"）、`strategy_groups[]`（portfolio×`strategy_activated` 授权映射，即 ≈策略归因）。全部为 shard 重算值透出。

**B. 九个派生数据集**（DS1 权益序列 / DS2 回撤区间 / DS3 round-trips / DS4 资金费 / DS5 周期收益 / DS6 绩效指标 / DS7 OHLC bars / DS8 决策链关联 / DS9 双口径+基准），统一文件头 `{schema, cutoff_ns, source_cursor}` 保证可复现；时间基准规则：经济序列 source_time 优先、到达分析用 receive_time。

**关键裁决**
- 管道宿主 = 扩展 Zig 重放探针单次 SemanticReplay 吐全部数据集；Python 永不解码二进制日志（单一计算路径）。
- Round-trip = AverageCost 释放事件（主键=产生释放的日志序号）；需核心侧 economics.Projection 在减仓结算处增加观测输出（不改状态机）。
- Benchmark = 基准品种 mark_price 归一化权益线（零外源）。
- 快照存储 = 版本化目录 + manifest（DatasetManifest 词条首次落地），含人工备注。
- K线回放 = mark_price 按 1m/5m/1h 窗口聚合，bar 带 fill_count 支撑成交叠加。

**fog 变动**：外部行情基准导入、stale 价格回退展示 → 新增两条 fog。
