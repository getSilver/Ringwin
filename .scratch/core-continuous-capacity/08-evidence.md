# 08控制与账户协调历史证据

状态：小规模功能验收完成，issue08已关闭。2026-10-16封存最终结果。

工作树：`D:\github\Ringwin-core-continuous-capacity`；分支：`codex/core-continuous-capacity`；基线：`b5a2d97690dc0ce1979e407694ff5d53ae2c949e`。只实施08，未修改原工作树，没有GitHub同步、部署或真实订单。

## 实现合同

Operational已完成命令、opened gate、resolved latch和不再被引用的策略fence，沿用decision stream的typed业务历史。先发布完整资格/明细，Core持久提交之后才释放；保留当前授权命令、OMS实际引用、未完成operation、未解决锁存和关闭gate。冷same只查证，旧EnableTrading不重新授权；expiry在查证前核对，冲突和查询失败保持风险关闭。

Cutover与账户Coordinator各自使用绑定account/control stream的持久单Writer、连续sequence和独立历史根。归档保留当前generation/release/schema、lease版本/占用、分片归属、token高水位和未完成协调。重启后Coordinator进入RecoveryOnly，必须有新鲜健康margin证据及仍有效的原lease才能完成恢复准入；归档不延长lease。

forced source在所有分片实际经济应用并持久ack后才能归档。完整source、原时钟、持仓、分配、分片owner和ack进入历史。Shard在首次forced前持久绑定唯一Coordinator stream；释放forced明细须认证该stream的完整闭合证明、原Core输入、原时钟、账户/portfolio/slice及完整分配守恒。完整账本与原source一并归档，当前经济状态和独立累计保留，exact经济窗口覆盖包含全部热/冷forced事实。未闭合source/ACK继续pin。

共享GatewayOwnership仅在真实源Owner的安全终态资格承接后释放完整路由，旧命令仍须查证，token永不回退。控制/forced根推进不释放accepted或Unknown。详见[ADR0016](../../docs/adr/0016-retire-completed-control-and-account-coordination-history.md)。journal/state/registry为39/43/37，Canonical schema13，Gateway snapshot8；历史root/page格式不变。

## 公共功能覆盖

| 验收要求 | 可复现入口与断言 |
| --- | --- |
| 各累计历史上限 | `control_archive_acceptance`：320命令、160 gate/latch、80 fence及80真实Core/Cutover切换，逐窗口归档/checkpoint/recover；Coordinator另12000摘要、400次轮转恢复并断言archive超过十个旧192KiB窗口 |
| 驻留风险不能全局阻塞无关控制 | `control_resident_order_acceptance`：一个pending-cancel订单保留reservation及原EnableTrading引用，40次无关命令归档后仍恰好保留两条有效控制记录，恢复digest一致 |
| 四分片账户归属和forced全经济证据 | `coordinator_history_acceptance`：320个source，每个四片各一slice；四个真实Owner各自应用、持久ack、归档完整source和全部forced posting、闭合exact窗口；每四轮Owner/Gateway/Coordinator实际恢复，最终各累计320、cursor321、仓位80，SDK0 |
| 共享路由与token | `coordination_gateway_acceptance`：320次顺序终态路由，逐次Store完整closure、Core终态归档，周期恢复；token2至321，旧token/命令拒绝，SDK0 |
| lease恢复与失败关闭 | `coordinator_safety_acceptance`：十轮四片风险分配/收紧及恢复，新margin与显式恢复准入前拒绝新增分配；过期lease不复活；热/冷same、冲突、wrong account/namespace/proof和查询故障均验证 |
| 归档/检查点崩溃边界 | 控制及forced的发布、Core提交、Gateway追加/checkpoint；Coordinator source的发布/追加/commit及seal/publish/rotate/reclaim；Cutover相同故障路径。恢复旧或新完整状态，未提交后缀只隔离、不采用、不改写物理字节；孤立首根关闭Owner |
| 完整认证与发送证据保留 | 同账户另一合法Coordinator stream的有效proof仍被拒绝；Gateway隔离协议测试分别推进control/forced根，accepted和Unknown在checkpoint/recover后逐项一致，发送为0。隔离协议夹具不替代公共Core归档链 |

## 开发期结果与修复

保留全部`08-*`原始日志/result。四分片forced和共享路由曾分别在有限默认模拟磁盘32MiB上触发NoSpaceLeft；测试显式使用128MiB/64MiB有限磁盘保存完整历史，Core live数组和生产默认配额没有扩大。完整强制账本按active posting前缀比较，不读取未初始化尾部。

真实故障暴露了MemoryAdapter已转移segment后errdefer重复释放，及forced开放事实accepted输入摘要与原source不一致；修复保持所有权及原语义摘要，未放宽snapshot校验。独立Spec/Standards发现与修复见[双轴审查](08-review.md)。首次候选v1只编译成功，期间两份源码变化，捕获明确记录drift2，未执行完整测试，不用于最终验收。

五轨迹和四分片摘要因新增持久状态/版本改变。原经济断言、独立重放及快照恢复比较全部先通过，再更新固定期望；原始不匹配日志分别为`08-trajectory-preflight`、`08-four-shard-preflight`。

v2完整ReleaseSafe实际执行602项，600通过、2失败，源码无漂移；全部新增08用例（包括四片320 source和320路由）均通过。旧cutover夹具在已有generation4时未声明当前schema，现明确为1，继续拒绝不兼容keep；其手写“每条record都当输入”循环随后暴露对forced派生承诺的错误解码，改用生产`recoverStableInto`逐组验证输入和派生事实，原经济、generation、ledger及完整digest断言不删减。该定向Debug已通过。生产合同测试的旧版本字面量同步39/43、前版38/42及registry37，定向ReleaseSafe通过。v2失败结果保留，未运行后续Debug/应用阶段，不能作为最终验收。

## 最终验收

最终冻结为[08-final-v3源码清单](08-final-v3-source-manifest.json)，107份源码，身份`1ac484f6586253131c2f8845821d54a6d4fc2b2edb63579d0d72dd9a41d02c71`。两模式完整测试串行执行，之后完成应用和CLI验证；全部10步实际终态退出0，源码清单逐项一致、drift0。

| 门槛 | 实际结果 |
| --- | --- |
| 完整ReleaseSafe | [602/602退出0](08-final-v3-full-releasesafe.result.json)，原生[日志](08-final-v3-full-releasesafe.log) |
| 完整Debug | [602/602退出0](08-final-v3-full-debug.result.json)，原生[日志](08-final-v3-full-debug.log) |
| 应用64MiB、CLI256MiB | 最终同源码重建退出0，两个产物各运行offline-fixture与windows-chain-test均退出0；[四产物哈希及PE实际栈](08-final-v3-artifacts.json) |
| Standards/Spec与夹具范围 | [双轴审查](08-review.md)、[最终Standards](08-standards-review.md)、[最终Spec](08-spec-review.md)无剩余确认P1/P2；[89份测试源码清单与26项夹具核对](08-final-v3-fixture-source-review.json)区分旧精确哈希审阅与08独立增量审阅 |
| 完整封存审计 | [149项核对通过](08-final-v3-acceptance-audit.json)：10步实际终态、107份源码、日志/四产物身份、两模式串行、六类十轮原生窗口、全夹具live/terminal上限及资格标志 |

入口：[run-08-final-acceptance.py](run-08-final-acceptance.py)，原生文件句柄捕获，每步记录source/日志/产物哈希，非零或源码漂移停止。[audit-08-final.py](audit-08-final.py)只核验实际完成结果，不运行测试或赋予资格。

复核命令：`python .scratch/core-continuous-capacity/audit-08-final.py 08-final-v3`。六类十轮原生输出在两种模式均为完整0–9序列：控制命令、暂停恢复、gate/latch、fence、forced source和共享路由。完整套件还实际执行80次Core激活、不可重定向Coordinator来源、15项协调安全回归及超过十个旧journal字节窗口的12000摘要/400次恢复。旧v1/v2、开发失败及定向日志均保留，不混用其源码身份关闭08。

## 保留范围

只验证小规模功能；每类live/terminal跨全部分片分别不超过100。320是顺序历史数量，400是forced夹具原始持仓lot；不是同时订单或压力负载。1,024 live、100,000生命周期、压力/RSS/索引成本、Venue及目标平台性能/生产资格仍未取得。没有线上Demo/Testnet/生产写入，Windows资格标志保持`production_qualification=false`、`read_only=not_run`、`demo_live=not_run`，总资格仍blocked。
