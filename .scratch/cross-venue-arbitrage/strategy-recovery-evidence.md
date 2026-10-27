# 10 真实策略状态恢复：Python离线证据

日期：2026-10-28。分支 `spread-arbitrage-strategy-python`；复核固定基点 `a9429c0dfab503f3946ace296c69bb1e30fedd99`。

## 实现与权威边界

`python/arbitrage_checkpoint.py` 的 `checkpoint(metadata, components)` / `restore(container, templates, expected=...)` 保存并恢复真实 `RollingWindow`、冻结 `AR1` / `RollingBaseline`、`Filter` / `FilterState`、`LabelTracker`、`Signal`、`Monitor`、`Admission`、`Cycle`，以及冻结 `Estimator` / `Calibration`。没有另建替代模型。模板仅提供已认证且可解析的冻结依赖；逐字段配置、完整模型参数、规则、原Plan全部内容的SHA-256必须精确匹配，模板的可变进度被显式schema覆盖。未知组件/字段拒绝；未决Admission重新关联恢复后的同一个Signal实例。

复用PortableStrategyStateJsonV1、严格重复键/字段顺序/整数界/容量校验、binary64 bits hex及有理数，以及现有Host QSSC容器、QSSD摘要和framing。真实组件采用**state_schema_version=2**；v1语义夹具兼容保留，未知版本拒绝，未添加隐式迁移。默认拒绝schema registry不符；调用方通过 `expected` 绑定definition/strategy/config等当前身份。核心尚须明确接纳v2格式，不能将Python codec通过当成核心已支持。

状态保存窗口顺序、filtered均值/协方差及更新阶段、未成熟预测、监测窗口身份及连续计数、信号/冷却/评估预算、原请求、阶段、意图参数/序号、原截止、冻结目标、匹配量证据及独立风险原因。包同时绑定baseline/state-space算法版本。Point和Parameters先验在运行入口统一binary64语义，避免大于2^53的整数观察/先验在checkpoint时才转换而改变结果。新增Signal规范入口使用 `identity=(strategy_instance, pair_ref, direction)` 和 `observe(..., cursor=ShardSequence)`，保存并核对原机会语义元组；省略身份或cursor的旧离线入口仍可运行，但已有触发的状态不允许伪称可持久恢复。grid和ShardSequence是不同字段，不要求相邻采样点的ShardSequence相差1。

周期的旧 `last_facts` 缓存改为完整输入的稳定内容摘要：同cursor重复仍去重，内容冲突仍拒绝；checkpoint不包含核心余额、持仓、OMS、Fill、预留和权限投影。`cycle_ref` / `reservation_ref` / `last_economic_ref`只是关联。后续经济决策仍须当前完整核心Facts。`_exit`同时清除旧 `before_reconciling`，修复退出后残留Reconciling前阶段的问题。

## 公共接缝与向量映射

测试从真实对象公开接口生成状态，经Host `encode_checkpoint/decode_checkpoint/state_digest` 与恢复接口后继续调用实际策略。容器字节完全相同即同时覆盖状态与QSSD摘要；断言均为严格相等，没有恢复容差。核心事实为明确注入的离线输入，不是假造真实日志。

| S6 | 本票策略侧证据与边界 |
|---|---|
| A/B | Filter/AR1/标签多个切点、Signal不同批次与重复grid、Cycle多阶段继续后状态/下一序号/Action严格相同；Host重复/旧会话和缺尾拒绝。真实canonical日志尾/完整输入batch重放由核心集成承担。 |
| C | 真实半匹配Holding目标40,000,000从原80,000,000冻结，恢复及退出保持；费用/修复成本继续来自当前核心经济输入，03/06已有4→5剩余贡献算例。 |
| D/E | t=100机会deadline110，已评估2次，111恢复评估失败且次数保留；Admission未决请求按原身份查询，成功事实晚到后消费同Signal，无第二请求。 |
| F | 原全订单覆盖、重复cursor/内容冲突、经济引用及下一修复序号保持；真实Fill幂等、归档认证仍是核心责任，09公开投影回归保留。 |
| G | 09双IOC Unknown保留原组/预留与前阶段，恢复继续查询，不盲目补单；Maker撤单/对冲Unknown待11实际实现后扩展，不能以v1夹具冒充Maker实现。 |
| H/I/J | 已触发退出且无减仓权限时checkpoint，后续原收益条件消失仍退出；Monitor InvalidLatched、未成熟/重复窗口、标签缺网格、日损失与restart原因隔离。 |
| K | 原修复/退出截止在停机后到期，恢复只升级不延时；回退时钟由Cycle拒绝。跨机可信时间证明及核心计时绑定待集成。 |
| L/O | 版本/依赖哈希、目标公式、进度、意图、phase、负方差/非有限数、未知字段和容量拒绝；模板失败不被部分修改。未解决引用不回收。 |
| M | 679999/680000/680001概率ppm、价格tick及目标原子边界，恢复前后完整评估/Action严格相同；signed zero/subnormal位保持。 |
| N | 真实Python Host子进程接受由实际Cycle生成的v2 checkpoint，返回同字节内容；旧会话请求拒绝。核心旧输出/旧ActivationIdentity拒绝仍待真实公共接缝。 |
| P | 同版本Keep依赖精确校验，旧配置/错误版本拒绝；未提供任意Migrate/Rebuild或Successor迁移。实际版本切换/权威激活由核心合同及独立集成承担，不能通过更换模板抹掉风险。 |

Python Host portable模式当前只接受checkpoint cursor等于恢复barrier；有日志尾需求时明确拒绝 `portable replay implementation required`，不会拿最新盘口补造尾部。实际模型连续/恢复决策在Python公开对象接口验证；将规范日志事件映射到这些接口、无权重放抑制真实输出、StrategyRecovered/HostActivated/显式新开仓授权、对账及持久发布顺序，仍归[独立集成验收](integration-acceptance.md)。本票不宣称真实核心日志尾或激活通过。

策略checkpoint不保存交易授权。测试证明当前 `opening_allowed=False` 时Admission拒绝，并且新激活清旧机会，必须重新采集信号。该Facts必须来自当前核心安全/显式恢复事实；Python传入True本身不是用户授权或核心资格。

## 命令与结果

- `python -m unittest discover -s python -p test_arbitrage_checkpoint.py`：最终18/18通过，5.502s；Spec补审独立18/18通过，6.069s；含真实Host子进程。
- `python -m unittest discover -s python -p 'test_*.py'`：最终172/172通过，18.158s，exit0。
- `python -m compileall -q python`：通过。没有独立Python类型检查器配置，compileall仅为语法检查。
- `git diff --check`：通过。

TDD：首个Rolling公开恢复测试因模块不存在失败后实现通过；Signal非法旧触发checkpoint先失败后补严；Estimator恢复边界测试先因不支持真实Estimator失败，加入明确冻结依赖类型后通过。Cycle全阶段恢复测试发现旧前阶段残留，修复后通过。大整数观察标签回归先因连续整数差1/恢复binary64差2失败，规范化Point入口后通过。复核3项回归先产生2fail/1error，修复后通过。

## 两轴复核

固定基点加最终工作树分别由两个独立子代理复核。Standards无文档硬违规、无必须整改气味；额外发现Signal静态实例身份未与包metadata互锁。Spec发现同项、Monitor空窗口可伪造健康恢复计数、Filter大整数先验初始checkpoint失败，均为P2。已加公开负例并修复：Signal及Admission配置无条件互锁、Monitor资格/健康计数必须由当前成熟窗口支持、先验运行入口规范化。补审发现1项P2：退出后Settling/Completed再遇Unknown是合法状态，原新增校验误拒；新增真实公开路径回归先error后允许三个退出后阶段，保持前阶段及首次退出原因。

最终Standards/Spec均确认无剩余发现，并核对相同SHA256：`arbitrage_checkpoint.py` = `555DDB2017CFE1B1B993E71AF903399194E54FDC8941C365D5C10B366C12DF0D`；`test_arbitrage_checkpoint.py` = `107C94142EC125DD324D2536B5F9A83C6F4D52B700CB7890E8B6827561265ADE`。Standards额外独立执行最后公开回归1/1通过，0.078s。复核后仅更新证据与tracker，不改源码。

## 可重复输入/摘要样例

以 `test_arbitrage_checkpoint.plan()` 的完整冻结fixture创建实际Cycle，并调用 `start(cursor=1, at_ns=T)`；metadata为strategy9/definition2/config1/schema-v2/cursor1/next3。不是核心生产日志。运行命令：

```powershell
python -c "import sys,json,hashlib; sys.path.insert(0,'python'); import arbitrage_checkpoint as r; import strategy_host as h; from test_arbitrage_checkpoint import meta,cycle,plan,T; c=cycle.Cycle(plan()); a=c.start(cursor=1,at_ns=T); raw=r.checkpoint(meta(1,3),{'cycle':c}); m,s=h.decode_checkpoint(raw); print(json.dumps({'input_digest':r.content(('Cycle.start',1,T)), 'container_sha256':hashlib.sha256(raw).hexdigest(), 'strategy_state_digest':h.state_digest(m,s).hex(), 'cursor':m['cursor'], 'next_intent':m['next_intent'], 'intent_sequences':[i.sequence for i in a.intents]},sort_keys=True))"
```

exit0；输入摘要 `8af0f3b38c5f4439069242ceae44d2f7065d8ced04314b2e961b109a4d23b2bb`；容器SHA256 `f10964680609af8bcc3a68e617d6d2db59cd51754d548f4f124ec658f2bfe85b`；StrategyStateDigest `58cb68850232b9c5a2ad6d703c210973a30eba10339b660b1bff02b5bb1d2edd`；意图序号 `[1,2]`，next=3。恢复样例及各切点/屏障的严格比较可通过同文件公开测试重跑。

## 未运行与资格

未部署、未真实或Demo交易、未写外部系统。未运行真实核心规范日志尾/预留/账本/激活屏障/网关/Venue路径，未取得跨平台数值资格。当前平台Python数学/恢复一致性不替代样本外统计资格12/13或运行资格14/15。GridSampler的行情缓存属于RebuildableState，恢复必须连续日志重放/重新预热，不能用当前盘口补造过去Point；本票测试从已准入的Point接缝驱动模型。
