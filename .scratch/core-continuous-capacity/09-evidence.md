# 09 小规模订单与安全背压功能证据

状态：小规模功能验收完成，issue09关闭。2026-10-16封存。工作树 `D:\github\Ringwin-core-continuous-capacity`，分支 `codex/core-continuous-capacity`，基线 `0779b48ec7a6f91e989f6d3c68049d0b012ff3dc`。

## 实现与范围

本票按地图最新小规模口径，不执行千单或容量压力。所有夹具跨分片的live、terminal分别不超过100；顺序历史累计不等于同时订单。四路观察夹具维持100 live上限，新增十轮夹具及mixed均远小于该界限。

- Coordinator订单摘要与Recovery/Cutover VenueEvidence计数由u8改为u16。Coordinator同时校验open+unknown不超过单片live设计上限；只传数值检查1024/1025、5120/5121，不构造千单。摘要独立snapshot8→9、digest域v9，publish_summary type1退役、type14承接新布局；旧快照和旧tail拒绝。Core/canonical未保存该DTO，各自格式不变。
- Trace、OMS、Adapter输出、canonical cursor/deferred admission与Store目录分配使用实际生产调用的纯边界谓词，检查最后空槽、满额和加一。没有清空幂等历史、跳过校验、重置序号或增大生产容量。
- 四Owner十轮均衡/热点链经Owner.apply、Gateway真实模拟发送、canonical Fill/Report、终态查证、业务归档、checkpoint及真实Owner/Gateway恢复；恢复实例通过持久RawIngress重放准入后接管后续输入。保留非零经济状态，冷Fill/intent/dispatch重复均无新副作用或发送。
- mixed场景保留两品种开平与独立减仓对冲的实际Fill/ledger，partial、PendingCancel、Unknown、resting与终态共存；同一屏障完整摘要/经济状态恢复且不重发。其两品种均为spot，不能单独证明资金费或跨Venue类别；三类别由四路unique500夹具的实际产品/方向/路由另证。
- 四实际Owner发布其真实占用到单一Coordinator，账户ceiling比总占用少1即拒绝，不能以其他分片或global余量掩盖。恢复保留分片归属、lease used及经济摘要，但不恢复发送权限。
- 安全背压四项检查覆盖关闭风险后合法回报/保护撤单/对账/fault继续、双历史lane超时与Fill推进及恢复重试、accepted/Unknown零重发、缺费用Fill立即停批且保留调用方输入、占用和已提交经济状态。

公共seam和所有计数/回收/失败关闭路径见[边界盘点](09-boundary-inventory.md)。五百个**独立**观察组合由`core_observation_capacity_acceptance`实际四路验证；新十轮夹具有500个Owner-local投影行、494个独立组合，共享genesis品种3/4不能重复计算为独立观察。

## 开发期结果

`09-*-red*`保留数值边界、旧方向或未实现业务的原始失败；并行开发capture的source drift不作为最终资格。Coordinator新布局和恢复计数、canonical admission、Adapter/Trace/Store纯边界已定向验证。四片旧基线夹具误用过滤名称的preflight实际执行5项，原日志保留，不与最终源码混用。

四片共同摘要因Coordinator v9字段布局/域变化而改变。`09-four-shard-digest-preflight`先通过经济及三条独立恢复相等断言，再在固定最终摘要断言处报告旧/新值；之后才更新期望为`c2580c48...fb0a6e4`，定向Debug通过。未删除原业务或恢复断言。

背压探索曾尝试在InvalidExecutionReport后继续批次，复核发现拒绝输入未进入OMS语义历史，继续同源会破坏整批重试。因此该不完整生产改动已撤回，最终Owner生产逻辑零diff。不能接受的事实停止批次、撤权并由调用方保留输入是验收的失败关闭路径，不宣称任何错误都可以跳过。

## 资源观察方法与未测项

`run-09-command.py`使用原生文件句柄分别捕获stdout/stderr，逐命令冻结源码、日志和memory样本身份；Windows GetProcessMemoryInfo每100ms观察**直接子进程**的working set及OS报告peak。编译器的RSS不当作测试RSS，完整套件与独立小功能sample另列；短进程可能无样本，子孙进程内存不合并。

新夹具用平台awake单调时钟记录submit样本数与总耗时，区间含必要行情刷新、Owner.apply、模拟发送、Adapter批次及维护checkpoint；不是裸Core延迟，也不是吞吐或p99资格。业务输入只用固定算术时钟，标识seed=`0x20261008`，不使用墙钟生成业务事实。

布局由实际`@sizeOf`输出。Owner.apply每次先复制一份TradingShard到未发布candidate，持久成功再复制回去，还存在Journal副本；这至少为`2 * @sizeOf(TradingShard)`的结构复制，另有内层回滚/digest/codec临时，不是平均复制或内存总线字节实测。OMS常见路径已有bounded undo，不能沿用旧盘点说所有OMS操作仍整份复制；冷路径fallback仍可能复制。

栈记录PE实际预留：应用64MiB、测试和独立CLI256MiB；线程**实际峰值栈未测**，不证明2MiB设计预算。测试helper改bootstrapInto消除一个按值大返回值；没有改应用栈或通过扩大栈掩盖新失败。

Store/OMS身份仍使用当前有界扫描/认证树路径；小样本查证正确性不能证明128B/项物理索引、90天保留成本或目标查询时延。MemoryAdapter的有限配额为夹具保留完整历史，不代表真实文件allocated disk。全部千单、压力、RSS/复制/索引预算和目标平台性能明确deferred；任何观察超过旧预算如实记录，不优化为“达标”。

## 最终验收

最终冻结110份源码：[源码清单](09-final-v1-source-manifest.json)，身份`7d70c32ad257806e99695fa9692822373977ca2c9410695be1541afd9627fc02`。完整两模式、应用/CLI及独立功能样本共12步串行完成，所有步骤退出0、source drift0；五产物和PE实际栈由[产物清单](09-final-v1-artifacts.json)逐项绑定。

| 验收 | 实际证据 |
| --- | --- |
| 完整ReleaseSafe | [616/616退出0](09-final-v1-full-releasesafe.result.json)，[原生日志](09-final-v1-full-releasesafe.log) |
| 完整Debug | [616/616退出0](09-final-v1-full-debug.result.json)，[原生日志](09-final-v1-full-debug.log) |
| 同源码应用与CLI | 应用64MiB、CLI256MiB重建；两个产物的offline-fixture与windows-chain-test均退出0，五条经济轨迹独立恢复相等，资格标志仍false/not_run |
| 独立小功能样本 | [ReleaseSafe 9/9退出0](09-final-v1-functional-sample.result.json)，含真实unique500/三类别、四片十轮、mixed、四项安全背压与共享账户 |
| 独立双轴复查 | [Standards与Spec](09-review.md)均无剩余确认P1/P2；Standards逐项比对最终110源码，Spec关闭三类别P2 |
| 封存审计 | [131项核对通过](09-final-v1-acceptance-audit.json)：实际终态、源码/日志/五产物身份、串行顺序、40次非零经济恢复、40次积压观测、三类别、输入边界和离线资格标志 |

最初绑定会话的ReleaseSafe进程8440消失且没有完成终态，该段只作[中断观察](09-interrupted-v1-observation.json)；原始日志和最后状态以`09-interrupted-v1-*`保留，未补写退出码或当成通过。随后验证原冻结编译产物的SHA256，隐藏后台进程从完整ReleaseSafe执行重新开始；其后完整两模式与后续步骤实际完成。最终ReleaseSafe从2026-10-15 17:21:52 UTC至17:53:50 UTC，Debug从17:54:41 UTC至19:16:23 UTC；中断前的片段不参与最终结果。

入口：[run-09-final-acceptance.py](run-09-final-acceptance.py)。复核命令：`python .scratch/core-continuous-capacity/audit-09-final.py 09-final-v1`。新运行需先生成独立prefix的source manifest；现有结果不可覆盖后冒用。`--resume-rs`只在逐项核对源码、原编译产物和日志哈希后跳过已完成编译，仍完整执行测试。

## 最终小样本资源与保留项

[运行身份](09-final-v1-identity.json)记录Windows 10 build17763、AMD64、4逻辑CPU与精确脚本身份；这是本地开发观察，不是Windows目标文件或生产资格。原生100ms采样及[资源观察](09-final-v1-resource-observations.json)可由`summarize-09-resources.py 09-final-v1`复算。

| 观察 | 实际值及解释 |
| --- | --- |
| 独立功能样本 | 9项，181.86秒，1802个内存采样；直接测试进程peak working set 911.96MiB |
| 完整套件peak working set | ReleaseSafe1127.20MiB、Debug1223.23MiB，均超过旧1GiB设计数值；包含测试夹具开销，不能当生产RSS实测或预算通过 |
| 结构布局 | Owner23,055,808B；Shard22,662,224B；OMS15,488,768B；Gateway75,811,648B；AdapterBatch347,152B；Canonical record10,848B；Command640B |
| 显式结构复制 | Owner一次提交两份Shard为45,324,448B，未含journal/内层回滚/codec/digest；该静态量已远大于旧64KiB参考，不是物理复制带宽实测，复制预算未取得 |
| 四片checkpoint snapshot | 非零经济十轮每片772,062B；独立unique500夹具最大831,817B；不能外推1024 live编码大小 |
| 队列/积压 | 四片主夹具采样live各1，归档前terminal0–3，Adapter batch高水位1，deferred0；mixed另5 live/3 terminal，历史背压另有两个持久lane和保留批次。不是满队列余量证明 |
| 最后轮模拟Store | 各片journal归档929,553/515,843/515,843/308,478B，history objects705,592/205,340/205,340/61,710B；tail各1 record/405B。有限1GiB夹具配额不等于allocated disk或物理索引成本 |
| submit观察 | 四片累计41/21/21/11项，合计约6.086/3.008/3.000/1.468秒；含行情、提交、模拟发送和维护，不能解释为Core决策时延或p99 |
| 未测 | 实际线程栈峰值、平均物理索引字节/身份、目标查询时延/吞吐、真实文件allocated disk、1024 live、100000生命周期、压力及平台生产资格 |

每项验收对应公共入口：三类别/unique500在`core_observation_capacity_acceptance`；均衡热点/40次非零经济接管和冷dispatch重复在`continuous_capacity_acceptance`；失败关闭与重试在`continuous_backpressure_acceptance`；共享账户真实占用在`continuous_account_acceptance`；纯数值与类型/旧格式拒绝在原所有者模块。每个夹具跨全部分片live/terminal分别不超过100，满额/加一订单边界只传数值；本次没有千单、压力或真实交易。

没有GitHub同步、部署、远程故障或Demo/Testnet/生产写入。Windows/Linux文件资格属于10/11；`production_qualification=false`、`read_only=not_run`、`demo_live=not_run`仍保持。
