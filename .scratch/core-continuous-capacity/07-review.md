# 07独立双轴审阅

最终源码：`a8c99fb7eed0cfa638d41caf0b1c37b42d8745a2447efab23bd6f29fd7235ccf`，96份Zig/build源码。比较基线为`903e5f32fbaac0d039d88a75bb5abe737bdf8036`，包括新增文件。全部子代理使用用户指定的`gpt-6.1-sol`、medium；最终Spec复核与对应实现代理独立，Standards独立只读。两轴无剩余确认的P1/P2。

| 轴 | 发现 | 修复与复核 |
| --- | --- | --- |
| Spec | P1：开放集合只内部自检，rehashed快照可用旧闭合冷身份替换新funding，后续旧包含证明仍有效 | 同组派生事实认证完整32B集合摘要：身份、经济摘要、原可信时间、accepted输入摘要、数量/时间汇总及cursor。41B真实派生日志逐字校验，正常重放独立生成；checkpoint仅pin当前一条，恢复核对承诺及热记录，open等于total或total-closed。公共回归覆盖hot/cold替换、时间/输入摘要篡改及退休原组后正常恢复 |
| Standards | P2：8槽baseline写入settlement和8项native时越界 | mutation前检查native+1容量，返回`EconomicBaselineCapacityExceeded`；公共Owner回归核对错误及完整digest不变 |
| Spec完成审计 | 第三资产费用和十资金费窗口原为两条独立历史，不能满足handoff明确组合要求 | 同一公共历史以BNB10开账，单笔canonical Fill fee3/rebate1，归档后零订单、永续持仓2；十轮均三资产窗口、全经济状态及Owner/Gateway检查点恢复、SDK恒1。未直接注入Projection或扩大夹具 |
| 独立组合Spec | 窗口查询未逐轮verifyResult；Fill仅核对native交易，完整记录断言不足 | 每轮窗口/Fill/Funding均认证请求、根、proof及record。归档前保留完整FillArchiveRecord，之后逐轮比较applied及全部ledger/count，再显式核对四笔native交易的方向、金额、资产、单位、layer唯一性和守恒。两项再次独立复核闭合 |

完整套件发现的回归也已逐项修复：四条承诺改为一条完整摘要事实，使原32Fill用例恢复通过；snapshot尾部编码实际调用Policy.counter，只限制16项物理前缀，不降低逻辑open20；强制执行待ack测试改用公共Timer/owned Fill建立原1单位/100成本，保留原forced/ack和拒绝漂移断言；快照更早拒绝的精确错误名更新；golden只有在经济断言及独立replay/recovery均通过后才由真实摘要更新。未扩大Trace/生产容量，未缩小原32Fill、四分片、十轮夹具。

最终Spec还核对完整资金费source与实际economic摘要分离、完整ledger/零金额身份、canonical未知归属及缺时钟pin、窗口exact coverage/from-through/逐资产before-after、不可重写baseline、Store→Core→Gateway相邻根与accepted/Unknown保留、热冷same/conflict、迟到事实拒绝及版本演进。强制执行未完成分配/ack继续pin，由08处理。

Standards核对原权威seam、有界数组、mutation/编码边界、显式caller-owned堆记录及生命周期；独立扫描81个含测试源码和18项夹具风险，见[冻结夹具审阅](07-final-v5-fixture-source-review.json)。每类live/retained-terminal跨全部分片不超过100；500观察组合不扩大交易夹具，未测试千单或容量压力。

实际运行、失败轮和未测范围见[07证据](07-evidence.md)。本审查不把静态复核、编译或定向成绩当完整运行或Venue/平台生产资格。
