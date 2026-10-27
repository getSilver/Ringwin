# 05 状态空间模型验收证据

日期：2026-10-27；分支 `strategy/05-06-python-model-evaluation`。
基点：`7fc5af2c164ea19fd182ec0477bfca9e7f9f5669`，开工工作区干净。
用户授权05完成后再做06；本记录仅证明05的Python数学和离线回放，不授予交易资格。

实现：[arbitrage_state_space.py](../../python/arbitrage_state_space.py)；
测试：[test_arbitrage_state_space.py](../../python/test_arbitrage_state_space.py)。
现有验收脚本加入本测试，04的Prediction模型种类增加state_space，复用Point、Rejected、
GridSampler输入语义、LabelTracker和现有binary64编码；没有新增wire协议或权威状态。

## 规格与当前源码

已读取05票全部要求、map、根GLOSSARY、agent本地tracker/domain规则及ADR0007；
核对算法附录2.2模型及2.3经济边界、S4模型参数/时效和S6模型专用状态/数值一致性要求，
继续遵守04已读取的信号、恢复及独立集成边界。当前strategy_state已有state_space的filtered
mean/covariance及prior字段，不沿用旧示例schema缺口。

## 公开行为

- `Parameters`不可变，显式绑定版本、训练截止、phi、对称PSD的2×2 Q、R>0、先验均值/协方差、
  预热、协方差上限及数值容差。静态Q/先验用二进制浮点的精确Fraction行列式拒绝非PSD输入；
  动态协方差检查有限值、非负对角、对称性及按scale归一化的PSD容差，容差内对称化，不裁剪负对角。
- `Filter.push(Point)`：F=diag(1,phi)、H=[1,1]；首个点使用登记的当时先验，
  后续先预测再更新；P采用Joseph形式 `(I-KH)P(I-KH)' + KRK'`。
  输出不可变filtered均值/协方差、创新、方差及单步log-likelihood，按固定顺序计算。
  不调用smoother，不读取未来值，不在在线路径拟合参数。
- gap/缺点/跳秒/break_before只重置模型先验和预热；没有周期、期限、风险或资金对象可供清除。
  协方差超限或尚未预热不能产生合格预测。中心单独漂移、回归分量为零时拒绝near_center，
  不能把中心漂移等同回归收益。
- `predict`与基线共用300/900/3600秒期限、Point/cursor/模型hash/方向记录，
  从当前filtered状态前向传播F/Q，观测预测方差加R。预测不改变过滤状态，不自动选择/混合模型。
  当前点早于训练截止不能用于样本外预测。
- `fit`：有界多起点创新似然pattern search；5个变换坐标分别为phi、Q两对角、相关系数及R。
  登记的初始状态分布随起点一起由训练似然比较，训练之外不改先验。先验不是由验证末端反推。
  只使用相同训练截止之前的规范Point，跨缺口重新先验预热，不拼接相邻对。
  所有搜索步长、缩步、停止、工作量和诊断阈值均为显式政策，不提供可交易默认数值。
  返回每起点初末NLL/收敛/失败原因、输入摘要、profile平坦方向、近似等价起点、噪声退化，
  并标识identifiable。零噪声/奇异相关起点显式报告degenerate_start，容量超限拒绝整个拟合。
  best finite candidate不代表收敛、可识别、全局最优或已启用；iteration_limit保留在报告中。
  identifiable也是局部数值诊断，不是市场统计或经济资格。

## 独立核验与实测

- 首次观测3、先验mean=(0,0)、P=I、R=1：filtered mean=(1,1)，
  P=(2/3,-1/3;-1/3,2/3)，独立字面预期；首点仍warming。
- 对40点固定输入，以60位Decimal通用矩阵、条件协方差减法（非被测Joseph实现）
  逐点核对均值/协方差，绝对容差2e-13；300/900/3600步均值容差2e-13、方差2e-10，
  包含Q非零相关项；逐点对称且PSD检查通过。
- 覆盖非法phi、非PSD/不对称/NaN Q、非法R/先验/预热、乱序、训练泄漏、协方差上限；
  prefix因果性、缺口恢复、同输入1/23条分块、公共标签接口均通过。
- 多起点测试加入训练截止之后的极端观测，报告完全一致；每个有效起点NLL不劣于其初值，
  小样本平坦/噪声退化保持identifiable=false，不能以重复起点冒充多起点证据。

已知状态合成：seed7505；中心随机游走sigma=.001，偏离phi=.8/sigma=.02，
观测噪声sigma=.005，400点；过滤连续运行，后200点对真实隐状态计误差。
预先写入测试的RMSE上限：center<.02、deviation<.02、sum<.01。
另以训练前160点、两个不同phi起点做离线拟合：

```text
center RMSE       0.011208141278625319
deviation RMSE    0.012436546906312778
sum RMSE          0.005049998295679491
fitted phi        0.8091411117439881
Q                 (4.481689070338067e-06, -4.164879380157984e-05,
                   -4.164879380157984e-05, 0.0004000000000000001)
R                 6.795704571147618e-05
evaluations       252
flat              phi, q_center, q_correlation, r
identifiable      false
```

有限样本不能可靠区分中心/回归/观测噪声；合成phi接近真值也不解除平坦诊断。
过滤误差用登记真参数测得，不冒充拟合参数的样本外选模或真实经济证据。

## 实际命令与边界

Windows PowerShell，Python3.9.18，无新增依赖：

```powershell
python -m unittest discover -s python -p test_arbitrage_state_space.py
# 11 tests, OK
python -m unittest discover -s python -p 'test_*.py'
# 73 tests, OK
python -m py_compile python/arbitrage_state_space.py python/test_arbitrage_state_space.py
# exit 0
python -c "import sys; sys.path.insert(0,'python'); import test_arbitrage_state_space as t; print(t.synthetic_report())"
# 上述实测
git diff --check
# exit 0
```

mypy仍未安装，未记静态类型检查通过。未运行Zig全套、真实Host接线、
checkpoint恢复/跨平台位级数值资格、市场校准、影子或任何Demo/真实交易。
这些由10、12/13及独立集成验收继续负责，不以本票测试代替。
两轴复核及关闭证据在05 Answer和本记录收尾补充。
