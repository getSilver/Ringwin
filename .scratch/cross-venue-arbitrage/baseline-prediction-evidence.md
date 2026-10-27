# 04 Python 滚动统计与 AR(1) 预测回放证据

日期：2026-10-27；分支 `strategy/04-python-baseline`。
起点：`d2bcb00993c35309df001da68cbd15ce30f8f018`（03完成后的干净工作区）。
用户明确要求处理下一Frontier 04；本次仅实施04，不继续认领05/06，不部署或交易。

## 交付与阅读依据

实现：[arbitrage_baseline.py](../../python/arbitrage_baseline.py)；
公开行为测试：[test_arbitrage_baseline.py](../../python/test_arbitrage_baseline.py)。
已加入现有 `python/verify_strategy_host.py` 验收列表；无需第三方依赖。

按04全部完成条件查阅map、04票，以及来源文档的相关规则：

- `strategy-contract.md`：第2/3节可见时间、模型版本与log统计量不等于现金收益；
  第10/11节状态所有权及配置/恢复边界。
- `algorithm-validation.md`：第1节可复现输入，第2.1节滚动/AR(1)公式，
  第4节数值方法，第5节时间隔离与成熟标签，第6节V8缺口/泄漏。
- `parameter-contract.md`：第1/2节版本/时效/单位，3.2节网格/期限/窗口，
  3.4节新鲜度/双腿时间差，第4/5节生效及研究证据。
- `signal-monitoring.md`：第2/5节连续有效点、成熟/缺失标签及统计/硬资格分离；
  `state-recovery-contract.md`：第2–4节模型窗口、冻结参数、无损数值及恢复责任。
- `strategy-refinement.md` 的S1–S3与 `integration-acceptance.md`：
  本票不承接目标状态机、概率准入或真实集成资格。
- 原01访谈Q18–Q21及Q37的相关记录；05/06完整票据用于核对后续接口责任和Frontier依赖。
- 根GLOSSARY、仓库agent规则及ADR0007/0012；未修改领域模型、协议或权威边界。

源码核对：`strategy_host.decode_depth_snapshot`、`strategy_state.encode_number`/现有模型schema、
`src/market/depth_snapshot.zig` 的canonical wire，以及 `market_projection.zig` 的连续性规则。
当前源码已有双边深度与策略状态schema，未沿用旧规格中的示例状态/缺深度结论。
Venue序号允许非单位增量和有效重置，不能用“sequence必须+1”代替核心连续性证据。

## 公开接口与输入合同

- `GridSampler.observe/invalidate/sample`：直接消费现有decoder的canonical深度bytes，
  配对绑定两腿InstrumentRules和相同基础/报价Asset；只处理按ShardSequence顺序应用的事件及Timer。
  `visible_at_ns`是接收可见时间，`admitted_at_ns`是核心实际准入/应用时间，均不得晚于其后网格。
  每次sample是整数UTC纳秒的一秒网格，正好取当时最后已准入两腿；
  按规则换算tick到相同报价原子/基础原子后计算 `ln(mid_B/mid_A)`。
  输出不可变Point含grid/cursor、规则/序号/接收证据、资格拒绝原因与break_before。
  缺数据、stale、skew、失效规则及不健康不输出有效值；跳过网格不补点。
  健康/连续性必须来自核心规范事实；缺口事件用invalidate，即使下一网格前恢复也保留中断标记。
  迟到行情仅影响后续网格，已返回Point不会改写。解码失败或乱序事件抛Rejected，不得继续正常建议。
- `RollingWindow`：版本化显式容量、warmup、最小方差和中心拒绝阈值，连续有效样本范围2…3600。
  缺失/跳秒/中断清模型窗口并重新预热，不涉及周期或风险锁存。
  按固定顺序用fsum和两遍法重算样本均值、n-1方差及Z-score，不在checkpoint时另行量化。
- `fit_ar1`：离线OLS仅使用训练截止点之前的连续相邻有效秒对；
  拟合intercept及phi，再换算center，残差方差按n-2自由度计算。
  参数对象不可变，预测不调用拟合；phi不在(0,1)、近单位根超政策、退化方差或样本不足均拒绝。
- `AR1.predict`：支持固定候选300/900/3600秒。使用log1p/expm1实现近单位根下的
  条件均值/方差，输出half_life_seconds及 `d*(S_current-E[S_future])`；d=+1多A空B。
  方差仅为模型内部诊断，不是完整经济风险区间。
- `fit_rolling` / `RollingBaseline.predict`：训练前传入并冻结偏离/波动分桶边界、
  方向、期限及最少样本；保存同桶成熟后续变化均值/样本方差。边界使用bisect_right半开分桶，
  偏离按direction*Z-score分桶，预测均值为当前S加同桶历史变化均值，不外推到完整均值回归。
  缺失标签单列计数；due恰在训练终点及之后的标签全部排除，未来观测不改变已拟合模型。
  空桶、样本不足或窗口版本不匹配均有明确Rejected原因。原始桶样本数不代表独立有效样本。
- `Prediction`：不可变记录含模型种类/版本/内容hash、生成Point/cursor/可见截止点、
  horizon_seconds、原due_ns、方向、均值、方差及半衰期。内容hash绑定数值算法版本和
  现有binary64_bits_v1无损编码，参数和分桶边界在内容hash中；在线不自动改模型。
- `LabelTracker`：pending上限256，与现有checkpoint每配对预测容量一致；实际调度必须
  选择容纳原期限的预测频率。满容量拒绝新增预测并完整保留旧记录，不能删未成熟标签换资格。
  只有正好due网格的有效端点可成熟，输出实际变化、预测误差及观察cursor/time；
  缺失或已跳过due记missing，不能以其后价格补回、不能填零；尚未成熟的记录保留pending。
  已返回关闭标签由调用者存留。标签为端点统计标签，中途缺口不伪造完整交易路径。

所有政策值均为显式输入，没有校准好的实盘默认值。输入NaN/Inf、非法时间/方向/窗口、
溢出/非有限统计及容量失败均拒绝，不把结果饱和成可排序值。
模块不创建现金PnL、OrderIntent、权限、账本或预留；03负责精确经济计算，
06将预测转换为联合经济场景。样本不足属于资格不足，不由本模块自动新增强制退出规则。

## 已运行的数学与回放验收

- phi=.5、center=1、innovation variance=.75，300步条件均值1、方差1、半衰期1秒，
  当前3时d=+1方向指标2、d=-1为-2；字面预期独立于被测函数。
- phi=.9和.999999999999，各300/900/3600步，以60位Decimal逐步递推及独立Decimal ln核对；
  均值绝对容差1e-14，方差1e-12，半衰期比值误差1e-14。测试的极近单位根政策阈值1e-15
  仅是数值测试输入，不是已批准的活动模型参数。
- 动态范围回归：center1/current1e16及center1e-18/current.01，phi=.5、h300，
  加权均值保留center而不被消去为0；创新方差1e-323、phi=.999999999999时，
  条件方差与60位Decimal递推误差不超过1ULP，不因先乘小分子而下溢为0。
- 手工训练0,1,2,2,3：独立OLS答案phi=8/11、center=4、创新方差3/11；
  训练终点之后注入极端值不改变参数；缺口不凑相邻对；预测循环不改变参数hash。
- 1,2,3滚动样本：mean2、variance1、Z1；跳秒、缺失及网格间已恢复缺口均重新预热。
- 线性合成训练的同桶300秒变化恰为300，字面预期预测均值607；900秒空桶拒绝。
  跨训练终点剔除、缺失标签计数、桶样本不足和窗口范围不匹配均通过。
- 规范wire→网格→窗口→AR1→标签回放，以1条/17条分块执行得到相同Point、Prediction、Label；
  包含不健康网格、非单位Venue序号，以及due前缺口后重新获得有效端点。
- 标签300/900/3600秒保持原成熟点；未成熟/缺失/重复/满容量和因果cursor倒退均有检查。

合成已知过程：seed=7304，`x_next=.01+.8*(x-.01)+N(0,.02²)`，
先burn-in1000点，再生成16000点；训练前12000点，未来区间取13个不重叠300秒预测端点。
预先写入测试的容差：phi±.02、center±.002、创新方差±.000025，绝对均值误差<.03、RMSE<.06。
本机实测：

```text
phi                  0.8010361118577247
center               0.010101945968214421
innovation_variance  0.00039607236927182555
mean_error           0.011886640574539743
rmse                 0.03678764127653949
```

这13个合成端点既不是独立市场样本，也不建立置信区间/参数选择的经济资格；
单种子有限样本有随机误差。研究中的raw桶样本允许重叠，12/13仍需独立时间隔离、有效样本与市场数据。
没有从这些测试自动选择或启用300/900/3600中的活动期限。

## 命令、结果与局限

环境：Windows PowerShell，Python 3.9.18，标准库。

```powershell
python -m unittest discover -s python -p test_arbitrage_baseline.py
# 24 tests, OK
python -m unittest discover -s python -p 'test_*.py'
# 62 tests, OK
python -m py_compile python/arbitrage_baseline.py python/test_arbitrage_baseline.py python/verify_strategy_host.py
# exit 0
git diff --check
# exit 0
python -c "import sys; sys.path.insert(0, 'python'); import test_arbitrage_baseline as t; print(t.synthetic_report())"
python -m mypy --version
# No module named mypy；静态类型检查未执行，不记passed
```

已运行先失败后实现的公开接口测试，包含标签因果检查先失败后修复。
最终测试计数：公开24/24、Python全量62/62，合成报告复跑一致。
未执行Zig全套、真实Host行情/Timer接线、checkpoint恢复/跨平台数值资格、
市场训练/独立样本外校准、影子或任何Demo/真实交易。
现有codec被复用不等于产品链路已接通；模型私有状态到现有checkpoint schema的实际接入归10与独立集成验收。
binary64按固定顺序计算，只报告本机资格，不声称跨平台位级收敛。

## 两轴复核及最终版本

code-review固定基点为上述03完成SHA，初始实现提交 `fa4c457d`。
标准轴发现Point.evidence可接收list、间接修改已返回预测证据，已改为只接受tuple并有公开回归。
规格轴发现AR1长期均值消去及极小创新方差下溢，已改为fsum的两项加权均值、
先算方差倍率再乘创新方差；独立数值回归已先失败后通过。
修复纳入工作树后两轴复验均无剩余项，规格复核者另运行24项公开测试通过。
代码复核与全量回归不替代市场或运行资格。

最终代码/测试SHA256：

```text
python/arbitrage_baseline.py EAF5F0605E51F31ACA44684218D97A82908F1AA95D9641739CA7D8498C225252
python/test_arbitrage_baseline.py A0EBD6925179E50E787A5C9AF0FE91310D7BC3184238FB5B4A2E6BFB85523AA8
```
