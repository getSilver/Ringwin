# 13 Maker–Taker：开发阶段离线研究工具

日期2026-10-28，分支`spread-arbitrage-strategy-python`；实施前HEAD/两轴审查固定点`a6484b91ecd2bbccf993390b29016a96f56a4e55`。用户明确目前无真实数据/市场，授权完成可开发范围；复用[12数据核查与协议边界](taker-calibration-evidence.md)，不重复全盘核查。

## 公开接口与适用范围

- `arbitrage_research.Protocol`最小追加`mode`（默认`taker_taker`）与`maker_scopes`。旧taker内容哈希保持兼容，Maker使用独立哈希域，不能继承双IOC选择。scope精确绑定pair引用、maker腿、目标lots、该周期实际报价ticks集合和entry/hold阶段，不外推未覆盖数量/报价；模型、执行、费用及参数内容仍由预登记候选哈希绑定。
- `arbitrage_maker_research.observe(cycle,facts,...)`只接受已由Maker公开`apply`消费的同cursor/时间/周期投影。数量来自已应用OrderFact，报价来自实际发出的post-only意图，Waiting从原始首次报价到观察时点，未取得所有maker报价终态经济覆盖时保持删失；不会把L2或未知撤单当真实成交。hold阶段要求当前真实Cycle.phase为holding。报告附加已实现对冲成本、不利选择、撤单中成交量及既有`queue_baseline`输出的预测量；这些标签的真实性仍需外部认证，接口不是新的权威事实来源。
- `summarize(...,maker_samples=...)`和`Study.validate/holdout`复用12四段时间隔离、全周期流量调整NAV、预登记试验预算、冻结及先消费一次保留区间的journal。Maker必须有每个周期的观察；同周期/阶段重复、外适用域、越界时间或身份不匹配拒绝。未覆盖预登记scope记`maker_scope_coverage`并禁止候选冻结。journal跨模式仍共享已见时间段，改mode不清除泄漏历史。
- 联合单元按等待时长×是否删失×是否Unknown×零/部分/全成交×对冲已成功/已失败/未知×是否撤单中成交统计次数，保留原始观察。Unknown独立于当前已应用量，即使当前零Fill仍保留可能成交风险。跨入/跨出/超跨度和未闭合完整周期的观察保留原始风险记录、计入excluded_observations，不进入校准cells。对冲失败频率仅有明确已知结果时给出；即使未见失败频率为0，`failure_probability_upper`始终None，不据此推断罕见失败概率为零。零成交的条件对冲为not_applicable。压力模型继续使用既有Maker `Stress`和联合场景；本接口不接收压力权重，不能将其计为经验概率。
- 每个scope独立报告entry或hold目标命中频率、Pi_plan与Pi_reference高估诊断、声明块数、队列预测量误差和观测到的不利选择/对冲成本尾部。参考结果缺失为None；缺失成本不填零。完整占用时间/NAV/亏损尾部继续采用12完整周期报告，未闭合周期不提供占用分位诊断。最大观测等待不是保守等待上界；各频率、均值、样本极值和声明块数均不是经相关性校准的统计界或有效独立样本数。

影响文件仅共享研究模块、Maker研究模块、公开测试和本票/map/证据；不新增依赖、撮合器、策略模型、Host/核心权威或运行入口。保留未跟踪`.scratch/zig-incremental-research.md`。

## 验证

- TDD首个公开Maker观察测试在模块缺失时失败，实施后通过；后续按公开行为逐步覆盖零/部分/全成交、删失/未知、无失败概率界、身份与模式拒绝、缺失适用域禁止选择、journal失败保留消费，以及实际Maker入场→对冲→Holding输出。
- `python -m unittest discover -s python -p test_arbitrage_maker_research.py`：9/9通过。
- `python -m unittest discover -s python -p test_arbitrage_research.py`：10/10通过。
- `python -m compileall -q python`：通过。仓库未配置Python静态类型检查器，沿用12已核查的环境，语法检查不冒充typecheck。
- `python -m unittest discover -s python -p 'test_*.py'`：最终211/211通过，21.984s；仅开发回归，不是实际保留研究。
- `git diff --check`：通过。
- 两轴审查：Standards无发现；Spec初审1项P2（零已应用Fill时丢失Unknown），通过真实Maker Cycle/Facts未知订单与possible_base公开回归先失败后修复，最终补审无剩余发现。独立Spec代理重跑9/9通过。

## 未执行与资格

未执行真实来源认证、真实队列/条件对冲数据校准、有效历史块估计、删失等待/尾部/阶段概率保守界、基线/挑战模型完整样本外比较、真实一次保留研究、完整策略收益风险资格。没有合格Maker参数包或交易授权；调用者声明historical、mode或合成夹具通过均不改变`economic_qualified=False`。

本票离线工具开发完成，状态in_progress、真实经济资格pending；15真实只读影子验收依赖仍pending。影子/L2不能补出真实Maker成交与条件对冲证据；本轮无网络请求、部署、真实/Demo交易或GitHub同步。
