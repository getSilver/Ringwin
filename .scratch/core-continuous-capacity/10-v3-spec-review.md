# 10 v3 Spec review

当前终态：最终小规模Windows文件功能验收通过，无剩余确认P1/P2。下文所有pending／不可关闭文字均为先前阶段记录，已由末节最终核对取代；不代表当前状态。

2026-10-16增量只读复核，基线 `4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。114源码SHA256 `f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42`；逐文件及六producer身份已核验0 mismatch。完整六脚本SHA绑定 `10-final-v3-identity.json:18`；与v2报告所列六producer一致，未修改生产者。

(a) 无新增确认P1/P2。issue10:19要求“贯通…归档、快照、文件重开及新进程恢复”，capacity-contract:144要求同一公共fixture真实文件与子进程。`src/windows_capacity_shared.zig:54`记录本轮真实Coordinator序号，`:66`仅有新发布时checkpoint：不变摘要保留已有完整检查点，没有需承接的新tail；变化摘要仍经公共Writer apply、持久checkpoint。未清空历史、伪造heartbeat或忽略Store错误，符合票01有序归档与检查点义务。

(b) 未确认范围扩张。修复限于文件验收夹具的维护调度，Core/Store生产合同未放宽；既有两处noinline拆分维持guard/qualification/事务发布顺序。新增 `windows_capacity_shared.zig:86`回归用小DTO只检查“变化→不变→再变化”的真实File Coordinator维护行为，不冒称真实订单业务资格；完整业务仍由mixed四Owner派生摘要覆盖。

(c) 未确认看似实现但错误。新增回归在不变调用后比较完整report及再次恢复，再变化要求barrier增长且恢复相等；`src/main.zig:263`显式测试引用确保发现。条件跳过仅适用于没有新提交的tail；有变化仍checkpoint，保留失败关闭。原三类别、500组合、mixed/shared、新进程、身份不匹配及18故障范围没有缩减。

实际v3 pipeline仍pending：v1各623绿不能抵消真实64MiB advance02失败；c29两处栈拆分越过旧失败但又暴露InvalidArchiveDescriptor，亦不能算完整通过。v3必须实际完成app64MiB/CLI256MiB各十轮新进程、完整Debug/ReleaseSafe及audit后再关闭issue10。当前无静态P1/P2不等于验收完成，不授予千单、压力、资源预算、断电耐久性或生产资格。

## v3实际证据中间核对（不可关闭）

已独立读取当前输出：app与CLI目录各30份process result，普通子进程全部exit0、各2次真实中断，所有recover文件清单前后相同；各十轮summary为passed，另500组合fresh恢复发送0。app-build/cli-build/ReleaseSafe result均exit0且source/producer mismatch为0；ReleaseSafe日志有最终624/624及“All 624 tests passed”。Debug run-state仍running、日志无最终终态，不沿用ReleaseSafe推定Debug成功。

按issue10五条AC交接核对：

1. **AC1公共File/新进程链：已有实际证据。** 两实际artifact各十轮/30新进程，含mixed/shared及独立真500/三类别；实际文件恢复不是内存快照。最终artifact封存和audit尚待。
2. **AC2故障/经济状态/零重发：已有ReleaseSafe及进程证据，待Debug与审计汇总。** 已有18场景日志及before/after精确kill恢复。故障为明确命名adapter hook或任务副本字节损坏，不能扩称真实OS ENOSPC/EIO或所有syscall中断；未执行矩阵项须保留not_run。
3. **AC3身份/平台/资源：输出已形成，待最终核验。** 源/producer、host、命令/种子、process库存、working-set样本、文件增长/恢复时间已留存；完整artifact/buildSHA、全部log/hash及最终source一致性由audit终审。实际栈峰值、索引成本、瞬态队列峰值仍未测，不能把末尾队列或PE预留当峰值。
4. **AC4文件语义/独立资格：功能结果有边界。** 已读native probe两代普通file sync/flush、replace、reopen成功；两次directory FlushFileBuffers均result0/error5。目录耐久性仍unqualified，不得将functional pass改称断电耐久、平台性能或Windows生产资格。千单/压力/资源预算均deferred。
5. **AC5范围限制：未发现越界。** 当前仅离线模拟与自有数据/进程，无在线交易、凭证或破坏性目标机断电；外部NodeFence、转储保护及完整生产资格未证明。

仍须等待：Debug完整成功终态→最终artifact身份封存→audit通过→报告同步真实失败/not_run与资格边界→范围明确的commit。当前无新增确认P1/P2，但issue10不可关闭；本段不是完整最终验收结论。


## 最终终态独立核对

已独立读取最终bundle七文件、audit及两mode实际result/log，未执行编译或测试。Debug/ReleaseSafe均exit0且各有“All 624 tests passed”；两artifact各十轮/30新进程，真实500/三类别fresh恢复、mixed/shared、完整authority和物理清单检查通过。audit实际570 checks passed。

身份核对：114源码仍f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42，六producer无漂移；封存identity绑定的183份原始输入hash、4份实际artifact hash及retained-failures的36份原始result hash均逐项核验0 mismatch。不是只信summary通过文本。

五AC终态：

1. issue10:19及contract:144的同公共业务File/新进程链已实际满足，两个产物分别完成十轮，所有订单夹具≤100 live/terminal。
2. issue10:20的故障/恢复/零重发已证：每mode实际9 Owner hook＋6物理或认证拒绝＋3 Gateway hook，共18；两产物共4次精确kill及2次启动前artifact guard拒绝。认证错误schema/artifact的Store physical ready而Core拒绝，区别于物理损坏；accepted/Unknown未重发。
3. issue10:21平台/身份/资源/失败留存已封存：identity/workload/samples/resources/faults/summary/retained-failures齐全；12项not_run与36份历史失败result保留，没有将旧v1绿、c29失败或开发probe覆盖为最终成功。
4. issue10:22文件语义及独立Windows交接范围明确：普通文件功能通过，但native两代directory flush均0/error5；bundle directory_durability=false、power_loss=false、production=false，capacity_stress=deferred。实际栈峰值、索引成本、预算及瞬态队列仍未测，不因functional pass取得资格。
5. issue10:23无越界：只证明自有文件、进程及离线模拟；未授予线上交易、凭证、破坏性断电、dump、外部NodeFence或完整生产资格。

结论：无剩余确认P1/P2，当前证据支持issue10以小规模Windows文件功能范围resolved；地图仅11为Frontier、12继续等待11，与依赖关系一致。root更新的issue/map未将目录flush失败、Linux或生产资格改为通过。后续仅文档封存与scoped commit不属于尚缺功能验收；提交状态由root另行确认。
