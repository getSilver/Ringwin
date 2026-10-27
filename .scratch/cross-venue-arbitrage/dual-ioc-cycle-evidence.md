# 09 双 IOC 策略侧离线证据

日期：2026-10-28。分支：`spread-arbitrage-strategy-python`。复核基点：`4d6f5be2f74990c0fed76ffabe676e692f3c63eb`。

## 范围与公开接口

`python/arbitrage_cycle.py` 的 `Cycle.from_admission` 将08的 `Request` / `Option` 与不可变 `Plan` 的完整经济腿、策略policy、规则/产品、配置/执行模型身份、数量及收益目标绑定，并复算公开06评估核对场景/估计器摘要；`start` 产生一个连续双成员组，`Action.encode` 复用 `strategy_host.output_frame/output_group_frame`。既有分组codec增加可选第二腿参数，保留原测试驱动调用。开仓是完整组建议，后续修复/退出也是建议；任何输出均不是核心命令或发送权限。

08目前只有 `execution_hash`，没有结构化执行配置内容。`Plan`的价格、次数、时限、损失预算必须来自调用方认证的同一执行配置版本；哈希相同本身不能证明参数内容一致，真实配置解析/绑定仍待集成。不能把此离线输入约定当成配置已通过生产认证。

`Cycle.apply(Facts)` 消费调用方认证的原周期完整投影。`OrderFact.applied_lots` 是核心唯一已应用经济数量，不能传OMS报告累计量或驻留Fill条目求和；`positions` 是经济投影剩余净基础资产，`economic_entry` 是当前成本/实际费用更正/已完成净收益的非重叠投影。策略不应用Fill、不造余额、不授予预留，也不处理Venue私有协议。报告先到与Fill先到在测试中表现为 `economic_complete=False`；未覆盖经济事实时只查询，覆盖后才行动。热重复、冷归档重复、迟到通过认证投影进入，重复不会直接成为第二次经济增量。

未知状态只按原序号查询、保留核心周期/预留引用及 `possible_base`；整个不确定区间内保持零新增意图，是保守安全动作。不以超时创建身份或第三腿；升级不会增权。`safe_reduce_lots` 必须由核心当前投影提供，已扣现货基础币费用、在途订单及不可消费/冻结残余；策略再次验证不超过现有基础数量，输出带 PortfolioReduceOnly，核心仍须最终检查。

修复仅补两腿已知差额，限制原数量、价格、权限、当前盘口、原截止、次数及实际修复损失加保守剩余修复成本。失败尝试减掉多余部分，不追原目标尚未成交部分。Holding前复用06 `assess_holding` /03 `holding_target`，只冻结一次；Holding不反复检查概率。正常止盈复用当前完整周期 `value_exit`，费用更正不降低目标；风险/模型失效/原期限优先。退出不回Holding、不重开已平仓位，次数、价格及原截止受限，无法合法减仓时明确升级。

日损失与回撤使用核心提供的NAV、累计外部资金流及同口径峰值；资金流不是收益。原因锁存不随NAV反弹消失，策略原因不替代核心SafetyGate。原周期闭合引用须覆盖**当前完整**订单、经济事实、费用、资金费及残余；更正或迟到事实使旧闭合失效时，调用方必须撤去 `closed_ref`。现货正余量不足一lot且核心显式承接才可完成；永续余量不能豁免。ADR0019残余可复用/人工冻结由核心拥有，不沿用旧最大存续期限。

## 10 的接续状态字段

实际实例字段：`plan`（原策略/组合/版本/入场建议/目标/价格/预算/全部截止）、`phase`、`before_reconciling`、`next_sequence`、`issued`（仅已提出意图的身份及参数）、`pending`、`cursor`、`last_at_ns`、`cycle_ref`、`reservation_ref`、`repair_used`、`exit_used`、`target_atoms`、`target_cursor`、`matched_base`、`first_exit`、`reasons`、`last_economic_ref`、`last_facts`（上一份不可变输入缓存，用于同cursor内容冲突检查）。绑定08时还有 `entry_cursor` / `entry_valid_until_ns`。10须明确编码/校验这些策略私有进度和原引用，或由精确连续重放重建输入缓存；不能从旧投影恢复交易权限。09未实现checkpoint。

## 命令与结果

- `python -m unittest discover -s python -p test_arbitrage_cycle.py`：最终21/21通过，0.444s，exit 0；Spec补审也独立运行21/21通过。
- `python -m unittest discover -s python -p 'test_*.py'`：最终154/154通过，13.345s，exit 0。
- `python -m compileall -q python`：通过，exit 0。仓库无独立Python类型检查器配置；compileall仅为语法检查。
- `git diff --check`：通过，exit 0。

TDD留证：首次公开测试因模块不存在失败；实现完整组后1项通过。部分成交/Unknown新路径先因 `apply` / `OrderFact` 缺失失败，随后4项通过；Holding路径先因尚未实现失败，完成后6项通过，再补充边界及反例到21项。测试只从公开 `Cycle` / `Facts` / `Action` /Host codec观察行为。

## 两轴复核

固定基点 `4d6f5be2f74990c0fed76ffabe676e692f3c63eb`；临时提交 `58dccb2b` 加最终工作树diff，两个独立子代理并行复核。

- Standards：0项；补审完整历史订单覆盖、正常止盈限价、Holding时效和准入规则绑定后仍0项。
- Spec：发现1项P2，`from_admission`未绑定完整InstrumentRules及产品类型，可更换规则版本999而仍输出建议。先新增版本/类型/摘要错误拒绝回归，确认3处失败；补齐完整腿规则、execution_hash及场景/估计器/收益目标核对后通过，补审确认P2已关闭、无新增问题。
- 双方补审确认最终 `arbitrage_cycle.py` SHA256：`A802944DAD767155430947EE8D530C542600F911936DE86CAB1F04D788404FEA`；`test_arbitrage_cycle.py`：`8816755713125CA7BC432E1211F36AB4C3C9DD321BC4FDB1157F7D3DF8416CB2`。

## 未运行与资格

I1–I5/I7–I8在本票仅验证策略侧版本化输入/输出及错误响应。未运行真实Python Host生命周期、TradingShard共同准入/持久预留、VenueAdapter输入、网关独立发送、归档认证或核心经济闭合公共路径；测试注入核心投影，不能宣称这些接缝通过。具体接线留在 [integration-acceptance.md](integration-acceptance.md)。没有实际命令或真实预留产生；测试中 `core-cycle/core-reservation` 等均是明确夹具引用。

公式/策略正确性属于本票离线范围；12/13统计与经济资格、14/15运行资格继续未完成。本票未部署、未执行真实或Demo交易、未写外部系统。
