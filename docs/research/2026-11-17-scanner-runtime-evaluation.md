# 正式扫描计划供应与评估接线

## 当前行为

`ScannerRuntime._step()` 已删除固定空计划调用：按当前范围、动态配对及最新规范盘口调用 `EvaluationInputs.build()`，把计划交给 `ScannerConsole.publish()` → `arbitrage_scanner.scan()` → 原 `arbitrage_evaluation.evaluate()`。没有新增价差利润算法或交易权限。

费用逐笔使用 `arbitrage_economics.estimate_fee()`；Taker 按真实深度和保护价执行 `sweep()`，Maker 检查不穿盘。原场景的联合成交数量、权重、部分成交、失败处置和未知暴露均保留。部分 IOC 成交可以低于提交订单最小数量。未来盘口通过既有 `_condition()` 在供应方声明的价格、深度及价差适用域内重基；超域拒绝，不修改校准以追随市场。

计划包含源策略、模型、入口及持有校准、费用、资金／风险约束和计算预算。入口费用、正向资金费预算和显式资本缓冲进入逐腿资金检查；资本因子由版本化风险输入提供，现货要求全额。最小数量、步长、合约乘数沿用实际 InstrumentRules；目录不含的最小名义约束由有版本的研究输入明确供应，不能默认为已知。零表示供应方明确声明无额外下限，不表示缺失。

采集序号是 Hyperliquid 规范盘口的合法组成部分。`arbitrage_economics.sweep()` 现在接受并校验 `sequence_kind=capture/capture_epoch`，保持原始字节与出处；没有剥除采集证据来适配经济计算。

结果区分 `evaluated`（通过）、`rejected`（经济／概率／硬门槛不通过）、`pending`（数据不足或预热）。缺失文件、模型、费用、最小名义约束、资金或具体校准适用域分别返回实际原因；计算预算失败仅使该候选不足，不停止其他候选。每轮完整替换；输入过期或规则变化不复用旧计划。页面显示拒绝状态和可用计算值，批准按钮仍要求评估通过且执行既有独立核心授权。

结果含数量、收益、概率、风险、有效期、模型／策略／校准身份和 `input_versions`（费用、资金、风险、规则、联合入场模型、参数包版本及摘要）。历史保存最终规范盘口、完整 Plan、失败原因及版本；复算调用同一评估器。

## 实际输入发布合同

研究模块现有 Report／候选身份**不是**运行参数包，运行入口不会将它们当成已具备费用、模型和合格校准。本次新增数据型参数包装载合同；没有把现有报告转换成合格证据的自动流程。

节点运行目录中的 `scanner-evaluation.json` 由节点内部研究输入生产者调用 `opportunity_scanner.scanner_evaluation.publish_inputs(path, document)` 原子发布。使用既有 `scanner_archive.freeze/thaw` 数据编解码（已登记 dataclass、Fraction、字节），不加载可执行代码，不提供接收 Plan 的 HTTP 路由，不导入测试夹具。

文档字段必须为：

| 字段 | 合同 |
| --- | --- |
| `schema` | `scanner_evaluation_inputs_v1` |
| `version` | 正整数，进程内单调；同版本换内容或倒退拒绝 |
| `clock_id` | 从 `/api/scanner` 的 `market.evaluation.clock_id` 读取当前运行时身份 |
| `source_kind` | 正常 transport 仅接受 `historical`；`synthetic` 只允许显式合成协议 transport |
| `valid_from_ns/valid_until_ns` | 当前节点单调时钟下的有效区间 |
| `cases` | 最多 256 个不可变的候选数量／模式输入字典 |

每个 case 包含：

- `key=(pair, direction, mode, maker_leg)`；`pair` 按观察身份排序；每条观察身份为 `(Venue, observation account, Instrument)`。
- 原合同对象：`policy: Policy`、`estimator: Estimator`、`calibration: Calibration`、`simulation_error: SimulationError`、`limits: Limits`、`bounds: RebaseBounds`、`scenarios: tuple[Scenario,...]`。
- 每腿二元 tuple：`target_lots`、`entry_fees`、`entry_limits`、`fee_valuations`、`fee_balances`、`funds_available`、`capital_factors`、`capital_buffers`、`entry_minimum_notionals`。数量使用各腿规范 lot；金额使用配对的规范 quote 原子单位。
- `funds_valid_until_ns`、`risk_valid_until_ns`、`risk_allowed`。
- `versions` 至少含非空版本引用 `fees`、`funds`、`risk`、`entry_model`、`venue_rules`。不能省掉未知的交易规则、资金约束或风险材料以产生通过结果。

每个数量及 Maker 模式需要其自己的策略／概率适用域。可供应多个数量，由原扫描器按评估通过、收益、资金占用排序；没有合适的数量证据时返回 `evaluation_case_missing`，不会自动生成校准或外推数量。数据来源真实性、独立块假设和资金额度仍由节点输入生产者负责；写 `historical` 不是取得交易资格。

当前进程时钟身份是保守边界：重启后不能直接接受上一进程的单调时间材料；输入生产者须基于可验证的时钟映射重新发布。装载器不会把旧时间戳平移成新鲜校准。仅策略评估截止和相对期限随本轮推进，模型哈希、校准、训练分区及材料期限保持原值。

## 确定性验证与边界

- `python/test_scanner_evaluation.py`：实际文件原子发布、三种模式、直接评估一致、正价差完整成本拒绝、版本冲突、重启时钟隔离、费用／模型／风险／资金／深度／规则／最小名义约束、真实网格预热、未知与失败权重、计算预算失败和公共 transport 拒绝合成材料。
- `python/test_scanner_integration.py`：HYPE、PURR 两个名单外品种分别经过实际 Zig 目录／盘口解码及正常 Runtime 计划生成，经 OwnerSession HTTP 返回真实通过与完整成本拒绝；直接评估一致、历史复算一致、费用过期立即替换旧结果。合成来源明确使用同报价／结算的 USDC 产品；没有将 USDT 与 USDC 当作同资产。
- 最终验证命令与结果在本地 06 的本次补充中记录。此前一次并发运行发生环境切换测试时序失败；该项单独复验和随后受影响全套均通过。中断恢复后的正式入口补验另有一次目录未登记失败，随后两项复验通过；该次失败根因未确认，没有修改生产超时或协调逻辑掩盖失败。

**未完成：** 现有经济合同按 quote 计算线性 PnL。报价与实际结算不同的具体产品返回 `settlement_conversion_required`，直到提供整仓经济换算合同；费用 FX 不能代替该合同。真实历史研究输入的采集、校准及自动发布尚无完整现成流程，本次不制造这些材料。未供应这些输入的正常应用会明确显示缺项，仍无真实线上机会资格。

本次未进行在线行情／真实研究材料验证，也未做浏览器完整操作验收或生产部署。页面仅做状态展示、类型及构建验证。自动接入尚未登记资产、报价／结算转换和真实材料供应的整体验收仍欠缺，06／来源规格 18 保持 open。
