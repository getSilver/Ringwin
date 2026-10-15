# 08控制与账户协调历史审阅

比较基线：`b5a2d97690dc0ce1979e407694ff5d53ae2c949e`。范围包含工作树修改与新增源码，不包含未授权的线上操作。用户指定子代理为`gpt-6.1-sol`、medium。

最终v3源码身份：`1ac484f6586253131c2f8845821d54a6d4fc2b2edb63579d0d72dd9a41d02c71`，107份源码。独立最终[Standards报告](08-standards-review.md)与[Spec报告](08-spec-review.md)均完成；两轴无剩余确认P1/P2。两个代理只读源码，完整运行结果由主代理冻结流水线另行验收。

## Standards

独立审查确认一项P2：public CoordinatorOwner.apply的热/冷`AccountFactIdentityConflict`没有关闭writer。修复补齐错误锁存，涵盖同类缺gateway证明；公共apply回归核对sequence、原source/ACK与经济状态不变。审查代理已复核修复，无剩余确认P1/P2；caller-owned批次借用和typed namespace限制一致。

## Spec

独立审查确认两项P2：任意驻留订单阻止全部命令回收；首次checkpoint前未提交后缀导致旧committed状态无法恢复。前者改为实际风险引用保留，公共回归跨40次回收；后者恢复精确committed prefix并隔离未提交后缀。独立代理再次复核两项修复，无剩余确认P1/P2。跨Coordinator来源信任为审查中提出的额外问题，后由主代理补齐不可重定向绑定及合法同账户错误stream证明的负例。

Standards：1项已修复、0项未决；Spec：2项已修复、0项未决。两轴分别保留判断。

## 修复证据及额外故障发现

| 轴 | 发现 | 当前修复与验证 |
| --- | --- | --- |
| Spec | 任意驻留订单会阻止所有控制命令回收，32槽仍可累计耗尽 | 按OMS实际trading_authorization的identity/barrier保留引用；保留当前authority和未完成operation。独立实现的公共回归保留一个未发送、占用非零reservation的订单，跨40次控制回收并checkpoint/recover，原EnableTrading和当前StopKeepPositions恰好两条驻留；256MiB Debug定向通过 |
| Spec | 首次checkpoint前追加成功、commit失败，恢复拒绝物理未提交后缀 | 恢复精确committed prefix，保留物理后缀但关闭Owner。新公共回归分别覆盖有快照和无快照路径，核对旧source/ACK及未提交物理字节哈希 |
| Standards | public CoordinatorOwner.apply的热/冷AccountFact冲突及缺gateway证明没有关闭writer | 补齐错误锁存，保持sequence、原source/ACK与经济状态不变；新增public apply回归，原14项Debug/ReleaseSafe及追加热冲突定向通过 |
| 跨所有者复核 | Shard只检查证明账户，未绑定其Coordinator stream | 首次forced前持久绑定唯一control stream；快照、digest、pin及Core归档资格均核对，禁止重定向。另一合法同账户writer发布相同source，证明本身有效但Core与Owner都拒绝其归档资格；Debug定向通过 |
| 故障回归 | forced开放事实被外层trace摘要覆盖，与原始source的accepted输入摘要不一致 | 保留forced原输入摘要，trace域不变；严格快照验证不放宽。Store发布、Core提交、Gateway追加与checkpoint四故障阶段Debug定向通过 |
| 故障回归 | MemoryAdapter在已将segment转移给archive后遇reclaim故障，errdefer又释放该buffer | 明确所有权转移，避免悬空archive；Cutover真实reclaim故障和后续恢复通过 |

独立Standards确认stationary caller-owned批次借用和typed namespace限制；独立Spec复核引用选择、committed prefix与不可重定向Coordinator绑定，未报告剩余确认P1/P2。其后主代理补充首个历史根已发布但释放未提交时的恢复隔离：即使旧逻辑root为空，发现Store head也关闭Owner。最终完整运行身份、后续发现及修复仍须见08-evidence，定向成绩不代表最终冻结验收。

## 验证范围

控制/协调归档不授予发送能力。Gateway新control/forced种类另有隔离协议测试，使用显式已提交源及持久dispatch夹具验证accepted/Unknown不被回收；它不替代Core完整归档证明。真实公共Owner全链由其他控制、四分片forced和共享路由回归覆盖。

每类live/retained-terminal跨分片合计不超过100。320为顺序控制/协调历史；forced每片只初始化一单并在循环前归档。有限128MiB/64MiB模拟磁盘承接完整历史，不扩大Core热表，不证明资源或压力资格。没有部署、真实Demo/Testnet/生产订单；生产资格保持false。

最终Standards另核对v3夹具清单哈希与当前冻结源码一致，确认08增量最多四片各一初始OMS订单、路由最多一单、控制零单、Gateway协议两条dispatch证明；320轮不累计驻留订单，checkpoint/recover保留。旧未变源码沿用此前独立审查并核对精确哈希，不能把本次增量复核称为重新人工审查全部89份历史测试文件。主代理的完整清单及范围记录见[夹具审阅](08-final-v3-fixture-source-review.json)。
