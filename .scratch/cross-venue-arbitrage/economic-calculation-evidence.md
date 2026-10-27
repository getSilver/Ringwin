# 03 Python 经济计算证据

日期：2026-10-27。分支：`strategy/03-python-economics`。
起点：`c27c7f021559a72cd15988a5203bbea802703747`；开工工作区干净。
用户本次明确授权实现03并要求新策略分支；地图中旧的“当前不实现”属于此前计划发布阶段。

## 交付与公开接缝

实现：[arbitrage_economics.py](../../python/arbitrage_economics.py)；
公开行为测试：[test_arbitrage_economics.py](../../python/test_arbitrage_economics.py)。
现有 `python/verify_strategy_host.py` 的检查列表已加入本票测试。

纯函数模块，不启动Host、不生成OrderIntent、不拥有账本或预留。只使用Python标准库；
经济输入限整数与 `Fraction`，不隐式接收 float/Decimal/string/bool。
`Decimal` 只出现在独立测试基准中。原子金额、tick/lot、乘数有理数、结果及容量上限均校验；
保守收益向负无穷取整，费用/预留/最低目标向正无穷取整，容量失败抛 `ValueError`，不截断候选集。

- `sweep`：直接消费现有 `strategy_host.decode_depth_snapshot` 返回的双边八档字典，
  绑定Instrument/规则版本、可见时间及有效期。输出逐档成交、未成交量、净价前名义金额和VWAP；
  缺失数量和价格边界停止撮合，深度截断不外推。订单最小量/最小金额在请求端检查，部分成交不伪造补足。
- `InstrumentRules.notional` / `linear_pnl`：价格tick乘每基础币原子的报价原子价值，
  数量lots乘每lot的基础币原子数。线性USDT合约乘数包含在后者中；不适用于反向或跨报价币合约。
- `estimate_fee`：逐Fill按有效规则、角色、扣费Asset及原子舍入计算。未知角色按taker；
  第三币必须有正估值及足额可支付余额。maker返佣不改善准入；已确认返佣单独传入 `evaluate_cycle`。
- `match_quantity`：现货gross基础币减基础币费用，再向下投影到对冲lot，分别返回匹配量与残余。
- `spot_liquidation`：现金流加净残余库存估值一次；基础币费用已进入现金/库存变化，
  只为费用归因加回gross后统一展示费用，避免再次计损。未变现残余不是购买力。
- `evaluate_cycle`：gross、实际资金费/返佣、逐项费用及缓冲分别返回；
  每个成本/风险身份只能属于expense、embedded、model_buffer、execution_buffer之一。
  已含实际成交冲击的滑点只归因，不再扣损。调用者必须使用相同风险身份，不能改名绕过去重。
- `funding_budget`：按每腿、每可能结算点的有向支付率逐项计算支出，再加不利缓冲；
  收入按零。实际收付走 `evaluate_cycle`，与准入支出分开。
- `expected_profit`：联合完整周期场景权重必须和为1，失败/零成交不删除；
  任一未闭合场景拒绝合格期望值，不能把Unknown记零。
- `entry_target` / `holding_target` / `remaining_target`：只提供S1/S2目标算术，
  不提供冻结状态机、概率资格或交易权限。
- `quantity_grid` / `choose_quantity`：外部已给定预算/深度/风险上界内的有界合法lot候选；
  每个候选仍须完整评估并传入硬门槛结果。金额与Edge严格超过门槛，Pi_plan最大优先，
  并列占用较小优先、再按lots确定排序；返回拒绝理由，不宣称连续最优或组合最优。
- `capital_required` / `funds_fit` / `spendable_budget` / `strategy_pnl`：
  不同资金组件去重、成本/预留向上取整；各ExchangeAccount分别比较，不能跨所抵消。
  只接收明确分配、已结算入账PnL、核心已去重占用，不接收浮盈扩大预算；外部分配从NAV变化扣除。

## 当前源码核对与调用者责任

已读取根GLOSSARY及ADR0001/0007/0017/0018/0019，核对
`src/model/canonical_event.zig` 的AssetAmount/InstrumentPrice/InstrumentQuantity、
`src/market/depth_snapshot.zig`、`python/strategy_host.py` 的深度decoder及现有strategy_state codec。
当前源码已有完整有界双边深度和非示例checkpoint schema，不能沿用2026-10-20旧缺口描述。
Python复用现有解码字典；不复制framing、Venue翻译、资金预留或权威经济账本。
新增模块当前由测试及验收入口调用；扫描器/交易策略的产品调用由后续票实现。

金额同属调用者指定的一个quote Asset；每个InstrumentRules绑定基础/报价Asset，
跨腿必须由调用者核对同基础Asset与相同USDT报价/结算、线性逐仓模型。
AssetDefinition原子精度与规则换算必须来自核心，不从本地小数猜测。
费用估值/余额/原币事实的身份、可见时间、去重、对账闭合和费用更正由规范事实提供方保证；
本模块不从OMS累计量合成Fill。`Fee`承接已去重实际费用，估算函数不得替代实际费用事实。
资金费列表须由调用者覆盖正常/最晚风险退出期限的全部结算点，分别调用预算函数。
浮亏、保证金安全、集中度、单腿失败、双腿健康与权限仍是外部硬门槛，
不能因 `funds_fit` 或候选选择通过就省略。
多笔场景订单必须由执行模拟器维护剩余盘口，不能重复使用同一静态 `sweep` 的可见流动性。
这些属于显式输入合同与后续集成责任，本票不宣称完成真实跨模块接入。

## 向量结果和边界

| 向量 | 本票已运行的经济结果 | 后续验收边界 |
|---|---|---|
| V1 | 5 / 0.811 / 3.989 / 3.489 USDT；Edge=34890/203 bp；另以Decimal独立复算 | 不证明模型缓冲已校准 |
| V2 | 买3支出302，VWAP=302/3；上限100仅成1剩2；卖侧支出方向与深度独立验证 | 不证明未来深度 |
| V3 | 0.5×10+0.2×(-4)+0.3×0=4.2 | 不证明场景权重有统计资格 |
| V4 | 方向指标为正；预计收入不抵支出，另加缓冲；实际收付可净额入PnL | 结算日程/支付率校准由后续接入 |
| V5 | q=2，Pi_plan=3.489，优于q=1/3；严格门槛及稳定并列测试通过 | 08负责多机会分配 |
| V6 | ceil目标8 | 06/09负责冻结、3持有/8.2触发与不延期 |
| V7 | gross1000基础原子扣1后净999，对应999个对冲lot；完整现金回放只损失费用100报价原子 | 不修改gross Fill lots |
| V8 | 未闭合场景拒绝资格；盘口缺量/过期不补全 | 04/12负责跨缺口拟合与标签时间隔离；09/10负责Unknown保留/恢复 |
| V9 | NAV130-100-外部分配20=10；预留非费用、各所分别约束、购买力不输入浮盈 | 风险锁存/回撤峰值由后续状态机与核心维护 |
| V10 | 半匹配目标4，原子边界4.0000005向上取4.000001 | 06/09/10负责一次冻结和恢复 |
| V11 | 修复-1后剩余目标贡献5，目标仍4 | 不重复计算已完成费用 |
| V12 | 剩余4.5加已完成-1=3.5，小于4 | 06负责S3概率判断，不能凭均值失败退出 |
| V13 | 10%匹配目标2；零匹配拒绝持仓目标算术 | 09负责无匹配不进入Holding |

## 实际命令与结果

环境：Windows PowerShell，Python 3.9.18，无新增依赖。

```powershell
python -m unittest discover -s python -p test_arbitrage_economics.py
# 25 tests, OK
python -m unittest discover -s python -p 'test_*.py' -v
# 37 tests, OK（含真实Host子进程checkpoint的既有回归）
python -m py_compile python/arbitrage_economics.py python/test_arbitrage_economics.py python/verify_strategy_host.py
# exit 0
git diff --check
# exit 0
python -m mypy --version
# No module named mypy；静态类型检查未执行，不记通过
```

已观察公开测试由缺模块/接口失败转为通过；新增负数亚原子资金费缓冲测试先失败，
修复为取整前拒绝负数后通过。独立Decimal基准、边界、确定性、成本单调性和容量拒绝均通过。
未运行Zig全套/跨语言Host验收脚本、行情数据校准、影子、Demo或真实交易；
本次没有Zig产品改动。数学正确性、经济统计有效性、跨模块集成及运行资格分开；
后几项未因此取得资格。复核结果与最终关闭状态见本票Answer。
