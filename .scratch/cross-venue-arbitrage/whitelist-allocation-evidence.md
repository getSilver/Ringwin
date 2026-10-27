# 08 Python 白名单准入、分配与信号重评证据

日期：2026-10-28；分支 `spread-arbitrage-strategy-python`。
基点 `8707980e2b6572de5840540707c6730d36ce86be`。
用户授权完成08；开工时07源码、测试及tracker已在工作区，未提交。本票复用并保留这些改动。

## 范围与公开合同

- [准入模块](../../python/arbitrage_admission.py)：`Config/load_config`、`Approval`、`Option`、`Facts`、`Admission.propose/reply`。
- [信号和模型监测](../../python/arbitrage_signals.py)：`SignalPolicy`、`Signal`、`Metric/Window/Monitor`。
- [公开回放](../../python/test_arbitrage_admission.py)：17项；现有 `verify_strategy_host.py` 增加本测试。

已读取根级GLOSSARY、issue/domain规则及ADR0007/0012/0017/0020/0021；只读核对当前
`src/trading/trading_shard.zig` 的周期资格及 `src/trading/cycle_occupancy.zig` 的账户品种占用。
核心拥有资金、周期占用、IntentGroup和预留；Python不建立影子余额、账本或OMS。
07/06的规范深度codec、共享经济/计划收益评估保持原样。

配置schema=1，明确版本、半开有效期、内容hash、信号政策、批次/数量/重算容量、
建议TTL、盘口时效/双腿偏差、批次窗口和占用时间下限。
必填引用覆盖策略定义、状态schema、VirtualPortfolio、激活、规则/资产/能力、
执行、退出安全、占用、网格、监测、风险、资金费、费用和估值。
引用以不可变hash表达；具体外部引用解析与权威屏障由调用方提供，不以本地hash自行授予权限。
JSON加载拒绝重复键、未知/缺失字段、浮点经济输入、错误单位和非法范围；
实际决策的核心配置hash必须与解析后的完整内容hash一致。
本票只校验08所消费参数及引用，不重复实现03–06校验器或09/11的执行参数解析。

`Approval`绑定完整两腿Venue/ExchangeAccount/Instrument、方向、模式及maker腿，
以及配置hash、激活引用、有效期、规则/政策/校准版本、模型/执行/模式资格hash。
输入只接受调用方从既有Web及权威事实验证后的投影，没有直接批准、网络或控制面写接口。
`Signal.activate`使用同次配对方向授权引用；首次/新授权清除未消费证据，
启用后重新观察重置/越阈值。授权/版本/时效缺失时不输出建议；禁用不清除active/pending。

`Option`是显式的预先正规化有限lots网格输入，每格携带07的完整Plan、两腿目标lots、
分账户资金需求、完整周期占用时长及执行证据hash。网格生成复用03 `quantity_grid`；
调用方按已冻结网格版本提供预算/深度上界、比例和深度耗尽点，不能省略合法格或截取线程结果。
每格重新校验lots、乘数、目标量、最小名义额、分账户需求与总占用一致性；
再用07 `scan` 调用06同一个评估器，验证当前规范行情、规则、费用、模型及概率证据。
只接受 `policy.at_ns == Facts.at_ns`，不消费旧扫描快照或推荐标志。
合格网格内按Pi_plan最大、占用最小、数量最小确定选择；并非连续数量全局最优。

先检查总预算、配对/基础资产/Venue集中度、逐账户实际资金和账户品种占用，
再精确计算 `Pi_plan / (occupied_atoms * max(occupancy_ns,time_floor_ns))`。
乘积与Fraction结果使用既有i128边界检查，稳定候选身份打破并列。
合成q=1/2/3的计划收益为8/16/9百万atoms，独立穷举期望q=2；总容量缩小时选择q=1。

一次 `propose` 至多返回一个 `Request`；这是策略建议及待查证身份，尚非OrderIntentIdentity。
调用方必须把它映射到09的真实组请求，并将权威预留结果送回 `reply`。
Unknown/超时保留原身份，返回query，不生成第二次预留；明确拒绝必须证明无预留/命令。
成功预留消费信号；下一次分配必须使用比响应cursor更新的完整核心投影，不能本地扣余额。
成功预留后同批次允许立即重算其余候选，仍计入信号总次数和批次重算容量；
没有成功预留不能利用此例外绕过最小重评间隔。新批次仍受原机会期限/次数约束。
批次窗口不延长；过期批次只停止新增建议，原pending身份仍保留。

信号按配对方向共享于模式、maker腿和数量，不由各候选制造多个信号。
公开接口消费已准入一秒网格的连续编号；同点重复/迟到不计数，缺口或资格失效重置。
连续重置后必须真实越阈值确认；机会TTL固定、初次计数、score跌破失效。
预留成功后即使全部未成交，仍须闭合、释放、冷却和重置；重复闭合不刷新冷却起点。
恢复逐原因匹配原事实及显式恢复引用，不清除其他锁存。

监测逐指标记录唯一窗口、成熟/有效样本、时效和连续warn/fail次数；
同窗口不可改写，重复窗口不增加计数，缺证据/跳窗打断连续证明。
全部指标连续健康才解除Warning；InvalidLatched须复核/对账/显式授权。
不变量失效清除旧健康证明，不能重送失效前窗口恢复。
`Monitor.actions`保持Unknown查询优先、失效退出优先于正常止盈；
Warning撤销入场且停止新周期，Holding不因一次p_hold下降新增退出，Exiting不返回Holding。
实际监测器及风险原因必须通过调用方持续投影到Signal的qualified/lock/recover输入。

## 验证与复核

采用Python公开接缝测试和红绿循环，无内部函数mock。
S5-A–M由触发/冷却/缺口/期限、资金释放、Unknown、预留消费、
窗口重复与证据不足、逐原因恢复、Holding/Exiting动作优先级回放覆盖。
S4舍入/概率/经济向量沿用03/06原有测试；本票补齐配置解析、版本/激活、范围及容量拒绝。

实际命令：

```powershell
python python/test_arbitrage_admission.py
python -m unittest discover -s python -p 'test_*.py'
python -m compileall -q python
python python/verify_strategy_host.py
git diff --check
```

结果：08公开17/17；最终Python全量133/133；语法编译和diff检查通过。
Host入口完成Python测试、Zig fmt、IPC 6/6和lifecycle 7/7；gateway经`zig-entry.py`
转为`src/entry.zig`全仓编译，持续数分钟后为控制本票扩展验证范围停止本次验证进程。
完整23步Host/Zig验收未完成，不记为通过；未改动任何Zig源码。
仓库没有配置mypy/pyright，本次使用语法编译及实际公开接口回放，未声称静态类型验证通过。

code-review两轴：Standards初轮0项；Spec发现同批次第一笔预留后其他候选被最小间隔阻断，
已增加两个独立配对同刻连续预留的正向回归及无成功预留不得绕过间隔的反例并修复；
独立复核17项通过，无剩余可操作发现。

复现输入使用`test_arbitrage_admission.inputs/ready`：Venue10/account1/Instrument1和
Venue11/account2/Instrument2，baseAsset2/quoteAsset1，方向+1、双IOC、lots=(1,1)，
policy/calibration/rules版本1，at_ns=10000、cursor=7、各资源剩余额度10亿atoms。
参考收益1000万、固定目标及实际计划收益800万atoms，占用2亿atoms、预计占用20ns，
Score=1/500（合成时间单位），建议截止10010。不是运行参数。

- 配置hash：`2ce9af6a4f3f29b13fcac338356661c02c45548a201a23b618cbafff9d23512e`。
- 请求身份：`6a1438b59d31036dd946f2f4ec72893703a24da1d7312885a1632ef9e21b8541`。
- 场景摘要：`c821bf88414eaa4b1a32227cd7d858ef157d7b23c0506997ff43614923e2a646`。
- 估计器摘要：`81a0034095ccbd9d3a077aadf1eea5b54434bf8afb49aeb4884ba242952464c4`。

本次提交只包含08；07预存源码/测试及tracker改动继续保留为未提交依赖。
单独净检出08提交不能代替同时携带07的工作区状态，不将07既有改动一并代提交。

## 未执行及资格边界

未运行真实Web批准/撤销路由、真实Host候选到组预留映射、Venue、影子、Demo或真实交易；
未部署、未同步GitHub。未校准运行参数、有效样本、占用时长上分位数或收益概率。
合成校准hash及样本只验证数学和错误响应，不提供统计/经济有效性。
策略状态checkpoint/重启续跑由10负责，08只保留可交接的私有进度与原请求引用。
实际接线继续在[独立集成验收](integration-acceptance.md)逐项留证；本票不授予运行资格。
