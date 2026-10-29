# 06 Python 固定目标与概率双门槛证据

日期：2026-10-27。分支 `strategy/05-06-python-model-evaluation`；
05关闭基点 `99b30387c1f020e2d587ece19f2c17fd7c9e7229`；06初始实现 `1242d59a`，复核修复另提交。
用户授权先完成05再06；本票只交付Python数学/离线合同范围，不授权部署、交易或GitHub同步。

## 实现与依据

- [arbitrage_evaluation.py](../../python/arbitrage_evaluation.py)：独立参考/实际计划回放、
  可执行完整周期收益、固定目标、可见前缀条件生成器及阶段门槛。
- [arbitrage_probability.py](../../python/arbitrage_probability.py)：时间隔离块校准、
  概率误差证据、有效块/成熟及缺失标签、保守ppm比较。
- [评估公开测试](../../python/test_arbitrage_evaluation.py)25项、
  [概率公开测试](../../python/test_arbitrage_probability.py)5项；已加入现有验收入口。
- `strategy_host.encode_depth_snapshot`为既有704字节规范wire增加逆编码，最后调用原decoder复验；
  不改变IPC/schema，不复制另一份深度格式。原桥接测试增加编码回归。

实施查阅同模块map及06完整票；`strategy-refinement.md`的S1–S3，
`algorithm-validation.md`联合块映射/校准/V6和V10–V13，
`strategy-contract.md`费用、周期收益、部分目标及现货尾差，
`parameter-contract.md`身份/时间/误差与适用域，`signal-monitoring.md`和
`state-recovery-contract.md`的阶段/成熟标签/原期限规则，以及独立集成验收边界。
领域依根GLOSSARY、ADR0007、仓库agent规则；复用03精确经济计算、04不可变网格Point/AR1、
现有规范盘口codec。05保持挑战模型，不因本票自动启用、投票或替换基线。

## 输入、计算及所有权

`Entry`为注入的假设/核心事实投影：已确认配对成交、真实已付费用、
已完成部分净贡献R_done、进入持仓的实际时刻及最后准入的秒网格Point。
零匹配为flat；Unknown保留原身份和可能敞口范围。
06消费入场/有界修复的结果，不实现09的真实订单或修复状态机。
`Market/Scenario`联合绑定两腿规范深度、费用估值/可用量、累计资金费支出、
风险/模型/Unknown事实、退出延迟、失败与原订单引用。权重必须精确和为1。

参考政策不使用尚未定义的目标；实际政策从同一外生场景独立开始。
Pi_reference非正或未闭合时不生成目标；否则只调用一次03目标公式，
Pi_plan扣自己的覆盖缓冲，用于净收益/BP准入及后续排序。
参考/实际政策引用必须不同；缓冲名称不可重复，也不可再次覆盖已付费用、资金费或执行价差。
实际净值不扣预测缓冲。方向/资产/净匹配量、费用作用域和时间均有校验。

当前可执行P_exit按逐档保护价sweep、逐成交费用舍入、第三币支付能力计算，
实际Y按精确到达时刻最后可见的盘口计算，不能读取下一条行情。
截止/参考退出计时器即使无行情更新仍触发；同刻风险、模型失效、到期先于获利。
触发后不回Holding。缺深度、未填完、未知或观察尾部不足均保留未闭合，净收益为None而非0。
迟报但在该腿平仓前结算的资金费进入最终Y，并保留到经济事实可见时才闭合的时间；
它不能倒灌更早的触发报价。未来资金费收入不能抵消支出，真实已结算贡献可通过R_done注入。

现货基础币费用不重复算作损失；退出gross数量需能承担基础币费用。
尾差只有在限额内且不存在可负担的合法最小清理数量/名义金额时才可估值闭合；
缺深度不能把合法未售仓位变成dust。估值折扣、单周期上限显式输入，
累计/时限资格及实际库存权威仍由核心和后续执行票负责。永续残仓不豁免。

## 条件估计器与概率证据

冻结Estimator保存训练截止前的联合历史块，不存外层未来答案。
按当前净数量、目标、R_done、剩余时间、模式/方向等精确特征域选行；不跨桶猜测。
生成器以当前已知Entry和首帧为起点，按历史同块的价格/数量相对形状映射未来路径，
保留同块延迟、失败、费用、资金费及风险相关性，不独立抽两腿。
两侧深度按当前/历史起点总量比例逐档向下取整；价格bid向下、ask向上取tick。
B腿附加冻结AR1从最后已准入秒网格Point出发的条件均值变化之差，
不把任意盘口更新重新当成秒网格样本。缺Point或超价格、价差、深度/点差范围拒绝。
同一冻结估计器可用于新UTC时刻/新价格的可见输入，且不改旧模型。

外层实际计划在未来进入持仓边界执行一次gate；内层假定已获准继续持仓，
只模拟固定目标和硬退出，不递归调用gate。外层后续实际走势无法进入内层上下文。
等待和修复消耗原绝对期限；已有Holding不新增周期性概率退出，Exiting不恢复Holding。
场景最多256、单路径帧最多8192、工作步最多100万、条件求值最多256；超限显式拒绝。

Calibration绑定模型、阶段、模式、特征域及simulation_hash；后者包括完整冻结历史块、
权重/费用/失败/延迟、重基界限、算法版本和执行政策数值/期限长度/缓冲。
替换历史支持、边界或保护价不能沿用旧校准。哈希排除校准自身，避免循环身份。
校准训练段之后须有不小于标签跨度的隔离；块身份唯一、不重叠且覆盖声明跨度。
每块等权，完整标签频率校准；缺失标签单列并使该桶不合格，不删失为成功/失败。

delta_cal使用**独立有界块假设下**的单侧Hoeffding余量（多桶分摊错误概率），
60位Decimal计算并向上取概率ppm。独立性/来源真实性须由independence_ref外部研究证明；
非重叠本身不能证明独立。模拟抽样另记录draws/错误概率/保守余量，不能冒充历史有效块。
完整枚举声明的有限支持可取MC误差0；这不消除模型误差。
重复误差覆盖、错误作用域、过期、样本不足和未成熟证据都拒绝。
下界向下取ppm、门槛向上取ppm，避免浮点边界误通过。

## 逐项验收

| 要求 | 公开证据/实测 |
|---|---|
| S2-A/B、S3-A/B | 参考10、目标8、实际计划6，金额门槛5通过/7拒绝；概率下界.68通过/.60拒绝，不回灌目标 |
| S2-C | A参考10/计划6，B参考9/计划6.5，按计划选B；08负责真实资金分配 |
| S2-D | 参考-1不生成正目标候选 |
| S2-E、V10/V11 | 修复亏损R_done=-1计入周期；原目标8、半量持仓目标4，剩余需5，目标不再次缩放 |
| S2-F、S3-G | 触发报价8.2、目标8、实际7.7：触发成功/实际未达标，Y=7.7 |
| S3-C | raw .80、cal .75、误差.06+.02，下界.67，门槛.70拒绝 |
| S3-D | 100条等权：50零成交、40合法触发、10风险退出，p_entry_raw=.40 |
| S3-E、V12 | 部分目标4、修复亏损1、剩余贡献4.5，P_exit=3.5，不触发；等原期限到期退出 |
| S3-F | 同刻风险/模型失效/到期优先，不计正常触发；无行情更新也按截止点触发 |
| S3-H/I | Holding不周期性重查；Exiting继续退出；缺条件证据退出，Unknown对账，到期不授予持仓 |
| V6 | 参考10=>目标8；P_exit先3后8.2，首次达标触发，延迟后闭合，不等更晚较高收益 |
| V13 | 原目标8、匹配一成仍用绝对下限2；零成交保持flat，不进入Holding |
| 联合执行及现金口径 | 真实逐档数量/费用、基础币及第三币费用、资金费、延迟和失败共同回放，不把log收益当现金 |
| 非闭合与安全边界 | 深度0、未知/删失、非法权重、重复成本、超限、适用域/期限、迟报成本及极端有限数值溢出拒绝等公开回归 |
| 无未来泄漏 | 相同可见前缀、不同外层未来得到相同p_hold；新时刻/新价格可生成路径；缺Point拒绝 |
| 独立数值核验 | 60位Decimal AR1闭式核对多步B腿修正及tick舍入，A腿保留同块残差 |
| 模拟器/校准身份 | 替换历史延迟、重基bounds或保护价时，两阶段旧校准均拒绝 |

## 实际命令及结果

Windows PowerShell、Python3.9.18、标准库，无新增依赖。

```powershell
python -m unittest discover -s python -p test_arbitrage_evaluation.py
# 25 tests, OK
python -m unittest discover -s python -p test_arbitrage_probability.py
# 5 tests, OK
python -m unittest discover -s python -p 'test_*.py'
# 105 tests, OK（含05的12项）
python -m py_compile python/arbitrage_evaluation.py python/arbitrage_probability.py python/test_arbitrage_evaluation.py python/test_arbitrage_probability.py python/strategy_host.py python/test_strategy_host_bridge.py python/verify_strategy_host.py
# exit 0
git diff --check
# exit 0
python -m mypy --version
# No module named mypy，未执行静态类型检查
```

TDD复现过：延迟读取未来盘口、遗漏独立截止计时器、合法未售库存被cap豁免、
基础币手续费使最小清理不可负担、深度缩放遗漏，均先失败后通过。
规范轴0项；规格轴发现深度尺度与校准身份未完整绑定，均已修复；
追加残余费用边界也修复，最终复验无必须修复项。规格复核者独立运行25+5项通过。

测试用校准为人工合成历史块（500块，每块4个标签、3真1假），只验证算术及拒绝合同，
不证明市场块独立、分布稳定或可交易。精确特征域及重基边界均是显式实验输入，
不声称有已校准的部署参数；实际数据不足时资格必须保持拒绝。
没有市场训练、独立样本外收益证明、真实Host接线、checkpoint/跨平台位级恢复、
影子、Demo或真实交易。未安装mypy，未执行静态类型检查或Zig全套。
经济资格归12/13、运行资格归14/15及独立集成验收；不能以105项离线测试代替。

最终SHA256（复核修复后）：

```text
python/arbitrage_evaluation.py 8F1AE6AB31B0121DCE8EF121862BBE73F80129F5A610EC6F1894181AD423392C
python/arbitrage_probability.py D5D92E60506ACCC9E02150F0314B7A8D7BF6F393A01CD5284C33A5C681336A3B
python/test_arbitrage_evaluation.py A9D0902E6EB89D0C8D82E1FFC10E8BB626C43B65B3579ADE24BDDF63F22762AE
python/test_arbitrage_probability.py 3B54639CFA62CF94558C4F3239B1CFD478F0FA2BDC73E383F523F5850F8A64F7
```
