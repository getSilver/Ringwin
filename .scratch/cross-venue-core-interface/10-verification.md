# 10 H1–H3 离线综合验收

本次会话于2026-10-29开始，验收收尾日期2026-10-30（Asia/Shanghai）。用户明确确认按离线范围完成，见[冻结合同](10-acceptance-contract.md)。基线 `477fc436`；本次不修改来源策略 spec，不部署或交易。

## 路径与证据层级

`src/testing/integration/strategy_host_recovery_integration.zig` 新增 `holding/keep/public_depth`：离线 MarketFeedAdapter 输出两个品种的双边深度，经 Owner 的规范投影和 depthSnapshotInput 发送真实 Python pipe。真实 Admission/Signal/Cycle 消费该深度；完整双腿 StrategyOutput 经 Gateway 验证，以原始 external_intent_group 提交核心共同准入，然后由持久 ExecutionGateway 在任何回报前分别调用两个 VenueAdapter。

随后串联报告先到、经济 Fill、重复 Fill、TradingPause、文件 checkpoint 发布、文件关闭重开、RawIngress 重放、账户对账、新 Host 会话追赶及持久激活。公共消费者和原连续路径的完整 QSSC bytes 相等，恢复追赶的完整私有 payload 相等，原订单/周期和核心摘要保持；恢复不开放新开仓。日志打印两份深度输入 SHA256、起始cursor、发布cut、激活屏障、next IntentSequence、订单/周期数量以及互不替代的投影/私有/核心摘要。

测试投影改为读取各账户独立 `appliedCanonicalFillQuantity`，不再用OMS报告累计代替经济应用量；两种累计分别保持。报告先到时应用量为0，报告中尚未承接的5000 lots保留为Unknown可能量；首次Fill后为5000，重复仍为5000。实际协议 normalizer、完整费用/资金费/残余及容量故障沿既有公共测试分别留证，不声称每个场景都经过完整Python链路。

## 可复现命令

工作目录 `D:\github\Ringwin`，Windows 本机、Zig `0.17.0-dev.315+5b647b792`、CPython3.9.18。输入为夹具，无网络/凭证。栈为536870912 bytes，不能推导生产资源资格。

```powershell
python -m unittest discover -s python
zig test src/main.zig -O ReleaseSafe --stack 536870912
python python/verify_strategy_host.py
```

第三条的恢复集成项实际执行 `python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912`，包括新增联合场景和原11个核心恢复场景。前两条分别覆盖以下Python与核心独立故障/容量矩阵。每份日志另存独立退出码，不从日志尾文字推测成功。

## 验收矩阵

表中 `R` 为上述恢复集成程序，`Z` 为 Zig 全量，`P` 为 Python 全量；场景名是源码中的测试标识。恢复cut/摘要见 R 逐场输出，具体故障切点保留在下列测试循环及既有验证记录。公共路径、核心及Python证据明确区分。

| 项 | 实际场景/入口、输入与断言 | 证据层级 |
|---|---|---|
| I1 | R `public_depth` 两腿704-byte实际规范盘口→Host→双腿输出；Z `03 depth resynchronization capture replay agrees at every failure cut` 对定义/快照/update/冲突/缺口/重同步九切点逐项比较Host wire；P baseline/scanner拒绝过期、规则错配和未知数量。 | 联合规范接缝＋实际OKX协议离线测试分别通过，不是网络Feed资格。 |
| V2 | Z `02 captured multi-level snapshot retains both sides at the public seam`：100×1、101×2，买3支出302；上限100失败闭合，不伪造成交。P economics同向向量。 | 双边深度/策略经济计算。 |
| I2 | R实际Host完整组、共同准入、两账户发送；Z `05b every joint append and commit fault recovers no half group`、`06 second IOC transport failure preserves first send and both reservations`。 | 传输、内部共同提交、外部独立发送分层；不保证跨Venue原子成交。 |
| I3 | Z `05b AC arriving before AB keeps the shared member uniquely occupied`及AB先到反序、资金竞争和发布故障；R文件恢复保持原周期。 | 核心竞争＋联合恢复。 |
| I4 | R报告先到/重复Fill/文件恢复，P真实Cycle消费投影；Z `06 Unknown and late dual IOC fills...`、`OKX raw private fills...`及`Owner reclaims ten partial...`两种顺序/冷重复。 | 联合普通费用场景＋独立真实OKX私有协议/归档公共测试；归档不是每次都经过Host。 |
| I5 | R `reconciling`和`maker`恢复，可能量/原身份保持且拒绝不合格激活；Z06原身份unresolved查询与不重发、减仓义务不穿零。 | 核心与Host安全边界；未找到/超时不能解释为未发送。 |
| I6 | R五阶段、普通/迁移/重建及public_depth，Repository重开、尾追赶、持久激活；P恢复及Host测试。 | 完整checkpoint bytes、私有摘要、序号和核心身份独立核验。 |
| I7 | R `exiting`、`loss`、`downtime`：目标4/亏1/剩余5，边界前后输出及退出后不回Holding；P精确tick/ppm/原子边界。 | 真实Host与核心减险输出＋模型边界。 |
| I8 | Z09a费用更正/基础币费用/残余/资金费/对账/外部分配，R `loss`及`risk`与核心持仓/NAV/原风险锁存；P日损失/资金流/跨日。 | 核心经济公共矩阵与策略合同分层覆盖；未把全币种生产DTO接线记为通过。 |
| S6-A | R真实模型15个checkpoint切点及五阶段文件恢复，完整payload相等。 | 08/09b公共路径延续。 |
| S6-B | P真实Host整批/逐条、重复帧/缺口/旧session拒绝；R连续与恢复相等。 | 实际pipe/framing。 |
| S6-C | R `loss`，目标8、匹配一半、亏1，恢复后目标4和剩余5。 | 实际核心经济事实及Host。 |
| S6-D | R budget保持2/3次及原deadline，停机后失效；P明确100/110/111机会向量。 | 真实Signal/Host恢复。 |
| S6-E | R私有Admission pending与已提交核心占用关联，原信号消费、单周期、原序号保持。 | 原请求及持久共同准入。 |
| S6-F | R public_depth报告先到/重复Fill＋原恢复；Z06两种顺序与归档后重复，核对独立经济累计。 | 联合＋核心协议/归档测试，非全排列均经Host。 |
| S6-G | R `maker`取消途中3000 Fill及hedge Unknown，可能量/预算保持且不盲目对冲；Z06/07取消与迟到Fill。 | 实际maker私有状态恢复＋核心安全路径。 |
| S6-H | R `exiting`已触发退出、恢复后原目标/首次退出原因保持，实际新减险输出沿原周期。 | 实际Host/核心。 |
| S6-I | R `risk` InvalidLatched与daily_loss/restart并存；解除restart保留其他原因/计数；P Warning与原因隔离。 | 实际Monitor/Signal/Cycle。 |
| S6-J | P `test_arbitrage_host`与checkpoint测试：未成熟/缺标签、重复监测窗口跨Host保存，健康计数不虚增。 | 实际模型组件及pipe，不声称标签由Venue推送。 |
| S6-K | R `downtime`及不可信UTC拒绝；P各阶段原期限过期，缺失/回退时钟不推测剩余额度。 | 实际Host/核心时间资格。 |
| S6-L | R错误schema/hash/模型/配置/缺尾拒绝，独立核心撤单保持；Z Store故障发布旧checkpoint。 | 公共拒绝及持久切点。 |
| S6-M | P九组679999/680000/680001ppm × 目标原子边界，1019/1020/1021 tick退出；R `loss`核心目标边界。 | 原08真实Host数值证据，本次P重跑。 |
| S6-N | R旧session/activation及错误激活摘要/屏障拒绝，无新预留/订单。 | 核心与Host双重边界。 |
| S6-O | R重复绑定/容量/非法比例/冷热意图历史及虚假敞口拒绝；Z09a历史与残余容量，不移除待决证据。 | 资格边界；非无限生命周期或吞吐资格。 |
| S6-P | R Keep/Migrate/Rebuild实际运行，Successor/cutover/fence后原周期/经济归属保持，新身份不得借旧周期开仓。 | 核心与文件重开，不是任意热切换资格。 |

经济细节及持久故障的输入引用/切点继续见[05](05-verification.md)、[06](06-verification.md)、[07](07-verification.md)、[08真实策略](08-real-strategy-verification.md)、[09b](09b-verification.md)、[09a残余经济](09a-owned-residual-economics-verification.md)及[09a整合](09a-integration-verification.md)。历史运行数不代替本次全量结果。

## 模式、平台及未执行项

H1为有界双边深度/重同步与Host输入，H2为完整组/共同准入/独立发送，H3为真实模型和原周期恢复/持久激活。各自只声明上表实际离线覆盖。Taker–Taker联合规范路径与Maker–Taker的策略/原生Post-only/恢复路径分别验收，后者没有取得完整maker模式运行资格。

未执行真实/Demo交易、真实联合网络Feed/执行、生产资金/参数校准、maker主动成交/队列位置/成交率/条件执行研究、Linux或其他Python/Venue资格、跨机可信时钟、物理断电、收益及连续容量资格。平台/Venue证据不互相继承。现有控制面产品接线与发布配置保持独立；本模块不关闭来源spec，也不把测试参数发布为生产配置。

## 最终运行与复审

待最终命令完成后填写实际数量、退出码与提交版本；此句存在时不得据此关闭10。
