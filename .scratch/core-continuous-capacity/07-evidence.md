# 07资金费、账本与对账历史证据

状态：小规模功能验收完成，07已关闭。实施工作树为`D:\github\Ringwin-core-continuous-capacity`，分支`codex/core-continuous-capacity`；未修改原工作树、部署或运行真实订单。

本页金额均为对应资产的原子单位，仓位数量为lot。模拟SDK和规范事件夹具验证公共业务行为，不表示真实Venue订单或协议资格。

## 实现合同

资金费资格保存原始Core/canonical输入、可信经济时间、账户/产品/资产/规则、原归属声明、实际已应用经济摘要及全部相关ledger。source摘要与经济结果摘要分开；零金额结算仍保留身份。canonical缺历史归属证明继续进入Suspense，不能根据接收时持仓自动分配。完整原始记录与独立累计通过typed Store历史持续承接。

完整对账窗口保存原规范事件、查询和来源、逐资产before/after、exact经济事实集合、前cursor及核对时经济摘要。先Store发布、Core持久提交，后释放旧窗口明细；新窗口from/before承接前through/after，初始baseline不重写。提交资格另绑定当前经济投影，不因行情及合法明细归档改写原窗口。迟到闭合区间的新经济身份或缺可信时钟失败关闭。

资金费/窗口通过原Owner与Gateway经济根协议推进相邻世代；accepted/Unknown发送证明不因经济根推进释放。journal/state/registry升级为38/42/36，Gateway快照7；Canonical事件payload版本和历史root/page格式未变。详见[ADR0015](../../docs/adr/0015-continue-reconciled-economic-windows-through-history.md)。

## 公共功能覆盖

| 条件 | 可复现测试与断言 |
| --- | --- |
| 完整资金费与ledger、零金额身份 | `funding_history_batch`及`funding_archive_acceptance`实际从Store读取完整资格和全部posting；验证归档前后余额、金额、守恒、source/economic摘要、热明细释放及累计不回退 |
| 零订单但有持仓、多结算周期及第三资产费用 | `Owner ten closed funding windows`：一次模拟SDK发送及成交，收BNB fee3并返佣1，归档成交/终态订单后订单为0、持仓2。BNB开账10、Exchange8/Portfolio-2/Treasury10随十次资金费及三资产窗口连续承接。每轮完整proof/record、Fill全ledger比较、Funding全部posting、Owner/Gateway检查点恢复和完整digest比较，SDK恒1，成本/保证金/PnL/初始baseline不变 |
| 真正空窗口 | `Owner complete empty windows`：零持仓、无新经济事实，十个完整窗口、连续before/after、checkpoint及最终恢复 |
| 重复第三资产费用及native余额 | 另有公共用例读取两笔完整Fill资格，每笔四个native交易（两layer的fee/rebate，共八条posting），核对-3/+1、BNB10→6与Portfolio-4，闭合三资产窗口并恢复 |
| 不完整证据保持失败关闭 | 漏事实、before篡改、漏closing余额、不完整bill、未知canonical归属、缺可信来源时钟、未解决经济门槛、hot/cold冲突及闭合through之前的新身份 |
| 故障恢复与零重发 | funding/window分别注入Store发布、Core提交、Gateway追加/检查点故障；另注入Owner检查点及恢复历史查询故障，恢复旧或新完整状态、cursor与累计，resume幂等、SDK计数不新增 |
| 快照交叉认证 | rehashed pending before和cursor余额/数量/root/时间篡改拒绝；hot/cold开放集合替换、原时钟/输入摘要篡改及OpeningBalance容量边界均有实际回归；真实journal41B重编码校验和后的截断与首末摘要byte篡改也拒绝 |

## 开发期原始结果

[07-public-slices-current-04](07-public-slices-current-04.result.json)为15/15定向Debug退出0，包含第三资产与十窗口模拟SDK；它是开发期结果，不代替最终冻结完整套件。早期编译错误、故障预期不匹配及SDK夹具准备失败均保留各自`07-*.log`/`.result.json`，未覆盖或计为通过。`07-public-slices-red-02`为过滤器错误导致零测试，不能作运行证据。`07-public-slices-red-03`暴露迟到事实错误回滚清除了安全锁存，修复后绿；`07-golden-format-red*`为格式升级后的旧摘要预期，须先经济断言和独立重放成功才更新golden。

## 完整失败轮及修复

`07-final-v1-full-releasesafe-build`因旧copy快照规范化路径引用不存在函数编译失败；修正后现有borrowed/copy编码一致性回归2/2通过。v2完整ReleaseSafe实际为561通过/5失败、退出1且源码无漂移（[原始结果](07-final-v2-full-releasesafe.result.json)），不计完整通过。五项分别为32Fill的TraceFull、强制执行待ack夹具恢复、四分片golden、快照早拒绝错误名、跨20Fill检查点编码；原日志和SHA256保留。

修复未扩容量或缩小夹具：开放集合的完整32B承诺改为一条41B派生日志记录，Trace/快照认证全32B，重放独立生成逐字核对，pin仅1条；原32Fill回归2/2通过。snapshot tail编码实际调用Policy.counter，仅clamp物理16项，权威open20原样保存；既有成交归档7/7 ReleaseSafe通过并新增original/recovered20断言。account coordinator原fixture直接Projection注入未journal成交，现改公共Core Timer/owned Fill/filled report建仓1单位/100成本，原forced/ack/recovery断言保留，定向2/2通过。四分片经济及跨片replay/recovery全部断言先通过，再更新实际golden；五轨迹按同样纪律更新并2/2通过。

## 最终冻结及运行门槛

源码冻结为`a8c99fb7eed0cfa638d41caf0b1c37b42d8745a2447efab23bd6f29fd7235ccf`，96份源码，见[最终清单](07-final-v5-source-manifest.json)。独立双轴补审无剩余确认P1/P2，见[审查](07-review.md)。

| 门槛 | 当前实际结果 |
| --- | --- |
| 完整ReleaseSafe | [567/567退出0](07-final-v5-full-releasesafe.result.json)，源码无漂移，原生[日志](07-final-v5-full-releasesafe.log) |
| 完整Debug | [567/567退出0](07-final-v5-full-debug.result.json)，源码无漂移，原生[日志](07-final-v5-full-debug.log) |
| 应用64MiB、CLI256MiB | 同源码最终重建退出0；两产物分别运行`--offline-fixture`和`--windows-chain-test`均退出0，见[产物身份与实际栈](07-final-v5-artifacts.json)。Windows链总资格仍为blocked |
| 独立Standards/Spec、夹具上限 | [审查](07-review.md)、[96源/81测试文件夹具审阅](07-final-v5-fixture-source-review.json)已完成 |
| 产物/日志身份及完整审计 | [129项独立审计通过](07-final-v5-acceptance-audit.json)，核对10步实际终态、96份源码、原始日志及四产物哈希、串行测试和资格标志；主代理再次运行同一审计退出0 |

运行入口为[run-07-final-acceptance.py](run-07-final-acceptance.py)，每步原生文件句柄捕获，非零退出或源码漂移停止后续流水线。ReleaseSafe可先`--compile-rs`，随后`--resume-rs`只复用已验证同源码、同命令、同产物及日志哈希的编译结果，完整测试仍实际执行；两模式完整测试串行运行。慢测试保留原进程，不重启已有活进程。

复核命令为`python .scratch/core-continuous-capacity/audit-07-final.py 07-final-v5`。最终套件中432覆盖完整资金费与零金额身份，436覆盖同一历史的十轮三资产窗口与Owner/Gateway恢复，437覆盖真正空窗口，433/439/441覆盖故障边界，434/435/438/440/442–445覆盖冲突、证据缺失与快照/journal认证。415/423的四分片夹具各为100 live及100 terminal，388验证500观察组合及100 selected。两模式均采用同一冻结源码。

## 被替代的候选身份

v3旧身份的完整ReleaseSafe确实567/567退出0，但运行中为补齐同一历史的三资产十轮场景变更了两份源码，结果如实记录`source_mismatches_after=2`，流水线停止后续阶段，不能作为最终冻结验收。v4为组合定向和清单候选；随后独立Spec要求加强窗口proof及完整Fill记录断言，最终以v5重新冻结。旧清单、结果与失败日志均保留，不混用其身份关闭07。`07-pre-final-v4-rs-build`参数错误及`-02`源码漂移预编译也不作最终成绩。定向`07-combined-proof-ledger-debug`2/2含main导入项，业务用例实际执行十轮；最终ReleaseSafe已在567项套件再次运行这条完整组合。

## 保留范围

仅小规模公共功能；每类live/terminal全夹具合计不超过100，500观察组合保留。千单、1024 live、100000生命周期、压力/RSS/索引成本和平台性能仍deferred。未完成的强制执行分配/ack继续pin，由08处理。Windows输出中的`production_qualification=false`、`read_only=not_run`、`demo_live=not_run`不提升。未取得Venue历史FundingAllocation、在线或Windows/Linux生产资格。
