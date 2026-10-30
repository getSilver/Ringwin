# 策略分析数据契约 v1 草稿

来源：[设计数据契约票](../issues/03-design-data-contracts.md)（grilling 全部按推荐落定，2026-08-26）。
状态：草稿——随 04 号票冻结入 spec.md。

## 总则

- **单一计算路径**：全部派生由扩展后的 Zig 重放探针在一次 SemanticReplay 中产出；
  Python 仅编排（调探针、落盘、起本地服务），永不自行解码二进制日志。
- **时间基准规则**：经济序列（盈亏、权益、资金费）取事件 `source_time`（缺失时回退
  `wall_time` 并标注 `time_basis: "wall"`）；到达/延迟类分析用 `receive_time`；跨
  epoch 不比较 `monotonic_time`。所有时间戳为 UTC ns。
- **金额单位**：一律 `*_micros`（i64），与核心一致；百分比字段显式命名 `_pct`。
- **KnowledgeCutoff**：每个数据集文件头携带 `cutoff_ns` 与来源游标
  （`{target_identity, last_sequence, journal_content_hash}`），快照可复现性据此验证。

## 腿 A · 实时投影扩展（ShardView 新增字段）

| 字段 | 类型 | 说明 |
|---|---|---|
| `realized_pnl_micros` | i64 | shard 重算值透出，不引入第二计算 |
| `unrealized_pnl_micros` | i64 | 同上（mark_price 驱动） |
| `cash_usdt_micros` | i64 | VirtualPortfolio 现金余额 |
| `fees_paid_micros` | i64 | 累计费用 |
| `nav_usdt_micros` | i64 \| null | mark_price×qty+cash；见估值规则 |
| `valuation` | enum | `"ok" \| "unknown"`；unknown 时 UI 显示"无法估值"，禁止显示 0（Q5）|
| `strategy_groups[]` | 数组 | `{strategy_identity, portfolio_identity, status, equity_micros}`，来自 `strategy_activated` 授权映射（≈策略归依据此实现）|

## 腿 B · 派生数据集 v1

每个数据集 = 一个 JSON 文件：`{schema:"<name>@v1", cutoff_ns, source_cursor, rows:[...]}`。

### DS1 权益时间序列 `equity_series`
- 主键 `(portfolio_identity, day)`；日粒度按 UTC 日界聚合。
- 行：`{portfolio_identity, day, equity_micros, cash_micros}`。
- 支撑：权益曲线、underwater 曲线。

### DS2 回撤区间表 `drawdown_periods`
- 主键 `(portfolio_scope, start_ts)`；行：`{scope, start_ts, trough_ts, end_ts|null, depth_pct}`。
- `end_ts=null` 表示进行中回撤。top-N 深度排序由 UI 侧完成。

### DS3 Round-trip 已实现盈亏流水 `round_trips`（Q2）
- "一笔交易" = **AverageCost 释放事件**：一次减仓成交按成本法结算的已实现盈亏段；
  反向穿越零点时按领域规则拆段（先平旧仓、余量开新成本段）。
- 主键 `(source_sequence)`（产生释放的经济事实序号，天然幂等）。
- 行：`{seq, ts, portfolio_identity, order_identity, instrument, direction,
  quantity_released, realized_pnl_micros, avg_cost_before_micros}`。
- 要求核心侧配合：economics.Projection 在减仓结算处顺带记录释放数量与 order 归属
  （只加观测输出，不改权威状态机）。
- 支撑：逐笔盈亏直方图/按序条形、交易透视表（策略=portfolio 映射 × instrument × direction）。

### DS4 资金费结算序列 `funding_series`
- 主键 `(settlement_ts, instrument)`；行：`{ts, portfolio_identity, instrument, amount_micros}`。
- 直接转写日志 `funding_settlement` 经 FundingAllocation 后的归属值。

### DS5 月度/年度收益 `period_returns`
- 主键 `(portfolio_scope, year, month)`；行含 `return_pct` 与区间起止权益。
- 支撑月度热力图、年度柱状。

### DS6 绩效指标集 `performance_stats`
- 输入：DS1 日收益率（rf=0）；Sharpe/Sortino 年化系数 √365（加密无休市约定，
  常数写入生成规则身份）；win rate/profit factor/max DD/CAGR 定义随规格冻结。
- 输出单对象：`{sharpe, sortino, calmar, alpha_ann_pct, beta, vol_ann_pct, trades_n, win_rate, payoff_ratio, profit_factor, expectancy_usd, max_consecutive_losses, max_drawdown_pct, cagr, definition_version}`。
- α/β：CAPM 回归，基准 = DS9 基准品种收益序列（rf=0）；alpha 年化 ×365。

### DS7 OHLC bars `ohlc_bars`（Q6）
- 来源：`mark_price` 事件流按窗口聚合；默认 1m，可选 5m/1h（参数进生成规则身份）。
- 主键 `(instrument, window, open_ts)`；行：`{o,h,l,c,fill_count}`。
- `fill_count>0` 的 bar 供 K线回放叠加 fills 标记。

### DS8 决策链关联表 `decision_chain_index`
- 主键 `order_intent_identity`；行：
  `{intent_seq, strategy_identity, correlation_refs:{risk_decision, command_seq,
  fills[], rejection?}, first_ts, last_ts}`。
- 由 `external_order_intent` / `strategy_intent_rejected` / OMS 事件在重放中关联。

### DS9 双口径与基准 `dual_pnl_benchmark`（Q3）
- `gross_cum_micros`（扣费前）/ `net_cum_micros`（扣费后）双序列；
- benchmark 序列：基准品种 mark_price 归一化为初始等额权益曲线
  `{benchmark_instrument, norm_equity_micros[]}`；外接行情导入记 fog。

### 快照存储（Q4 · 结果管理页后端）
```
snapshots/
  <UTC时间戳>-<slug>/
    manifest.json     # DatasetManifest 式：schema 版本集、生成器版本、
                      # 各数据集内容哈希、来源游标、备注（人工输入）
    ds1.json … ds9.json
    projection.json   # 当时投影视图副本
```

## 显式不做（本版）

- 外部行情基准导入（fog）；stale 价格回退展示（fog）；Python 侧日志解码（永久排除）。
