# 10 离线综合验收冻结合同

用户于本次会话确认：按离线范围完成；固定既有策略行为、schema v2、模型版本与明确的测试参数，部署/校准值及 Venue 资格另列未取得。该确认解除 10 的合同冻结前置，不授权部署或交易。

基线为 `477fc43699be357e41120137bfe72b42cdfdec70`，本次仅增加验收接线及修正测试投影，算法不变。依据为 [08 真实策略合同](08-real-strategy-contract.md)、[09 汇总](issues/09-cycle-recovery.md)、ADR0001/0007/0014/0017/0019 和既有策略行为合同；不修改来源 spec。最终实现提交及实际结果见 [验证记录](10-verification.md)。

冻结依赖保存在 `src/testing/fixtures/cross_venue_acceptance_contract.json`。`test_public_acceptance_contract_keeps_frozen_test_dependencies` 对两种模式各六个组件的完整不可变依赖重新计算规范内容哈希，包括执行计划、Signal、Admission、状态空间 Filter、机会预算和 Monitor。该文件用于检测测试合同漂移，不能作为交易配置加载。原始 v2 初态及模型/数值边界夹具继续使用 `strategy_cycle_recovery_v2.json`、`strategy_maker_recovery_v2.json` 和 `arbitrage_host_*.json`。

| 项目 | 冻结的测试值/语义 |
|---|---|
| 身份与格式 | strategy=9、definition=2、config=1、portfolio=10；账户20/30、品种101/102、Venue身份1/21；schema v2、QSSC/QSSD、`strategy_components_v2`及现有binary64 codec；值只表示测试身份。 |
| 双IOC | 每腿10000 lots，买/卖限价100/110；目标8 atoms、绝对下限1；部分匹配5000后目标4。普通修复、风险减仓及退出仍沿同一原周期。 |
| 行情 | 初始时刻1767225600450000000ns；101 bid/ask=100/101、102=109/110，每档10000 lots。depth wire v1，每侧最多8档；未知数量、缺口、过期和规则变化不能补造流动性。 |
| 时间与风险 | 原截止为上述UTC+10秒；修复截止比该值早1ns、退出截止晚1000ns；重启不续期。持仓期限、利润及原原因锁存不重新初始化。 |
| Maker | 原生Post-only、maker leg0，偏移0/1、最多2次改价，原报价/尾部期限1秒；仅离线合同值。原maker取消途中Fill与hedge Unknown保持原身份和可能量。 |
| 模型与状态 | 原模型版本1；显式迁移测试Filter版本2；冻结场景和校准夹具，无线上重拟合。窗口/标签、协方差、评估额度与研究seed仍由既有08/策略公共测试覆盖。 |
| 经济与权限 | applied quantity只能来自独立唯一canonical Fill累计，报告累计另保留；缺成交明细时仍有可能量。恢复不授予新开仓；残余规则未配置默认关闭，显式测试规则不成为生产Asset阈值。 |

公共验收接缝沿票中既定入口：`MarketFeedAdapter.tryDrain → Owner/TradingShard → depthSnapshotInput → Gateway.encodeBatch → ManagedHost → StrategyOutput → Gateway.ingest → Owner`，随后经`ExecutionGateway → VenueAdapter`、规范经济事实、Repository文件发布/重开、RawIngress重放及持久HostActivated恢复。比较可见深度、完整私有checkpoint、核心CanonicalStateDigest、实际意图、订单、预留和周期；不以Python账本替代核心。

新增联合场景的 MarketFeedAdapter 是显式离线规范事件夹具，VenueAdapter复用06的可控实现。真实OKX协议转换由全量中的原始行情/私有WS测试单独验证，不能把两段组合称作真实跨所网络执行。正常链路加报告先到、重复Fill、停开、文件重开与新会话构成混合故障；其余故障矩阵复用03/05/06/07/08/09的实际公共测试，并逐项区分证据层级。

Taker–Taker仅证明此Windows离线公共接缝；Maker–Taker分别记录Python/原生Post-only/恢复证据，未取得完整maker成交、队列可观测性或条件执行资格。Linux、其他Python/Venue、Demo、生产、真实校准、收益及连续运行容量均不继承该证据。
