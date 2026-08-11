# 研究数据存储与查询技术调查

研究日期：2026-07-27

## 结论

第一版采用一套单机、单副本、无常驻分布式服务的组合：

| 职责 | 首版选择 | 明确边界 |
|---|---|---|
| `SourceArchive` | 已确认的稳定版本化二进制事件段 | 不转成 Parquet 后再作为原始权威事实 |
| `ReplayDataset` | `DatasetManifest` 引用的稳定事件段；需要重组时仍使用同一事件编码 | `replay` 由专用顺序读取器提供，不经过 SQL、DuckDB 或 DataFrame |
| `ResearchDataset` | 不可变 Parquet 文件 | 服务 `scan`、聚合、特征和研究，不承担权威逐事件重放 |
| 物理存储 | Linux 本地 POSIX 文件系统 | 暂存区和最终区必须在同一文件系统；接受既定的 `1 副本 / 1 故障域` 风险 |
| 目录与血缘 | SQLite WAL catalog | 一个发布者写；读者只做短事务解析 `DatasetRef`，随后直接读文件 |
| 查询引擎 | 每个研究进程内嵌 DuckDB，直接扫描清单列出的 Parquet | 不把研究数据再导入持久 DuckDB 数据库，不建设 SQL 服务 |
| Python 互操作 | Arrow 内存模型／IPC 仅用于进程边界或结果交换 | Arrow IPC 不作为首版长期数据集格式 |

这套组合直接对应[研究数据契约](../issues/18-research-data-contract.md)的两种读取语义：`scan` 使用 Parquet + DuckDB，`replay` 使用生产核心已经能消费的事件编码。它避免为了单节点一副本部署 Iceberg catalog、Delta 事务日志、lakeFS、对象存储服务或独立查询服务。

**Parquet 不应被声明为已经满足 8 路合计 16M events/s 的重放格式。** 当前[事件编码原型](../issues/21-prototype-event-codec.md)在 Windows 上只验证了单流完整恢复扫描中位数 2.08M events/s，尚未验证 Linux/NVMe 上八流并发；Parquet 路径更没有完成列式解码、解压和事件重构基准。首版架构因此不让该目标依赖 Parquet，最终容量仍须由本文第 9 节的原型证明。

## 1. 工作负载决定必须分成两条读路径

研究数据契约同时要求：

1. 对部分字段、部分 Instrument 和时间区间做过滤、聚合与交互分析；
2. 按 `ReplayOrder` 把完整事件连续送入与实盘相同的交易核心。

这两个负载的最佳布局不同：

- Parquet 把表拆成 row group 和 column chunk，文件尾元数据记录各列块位置；读取者可以只读需要的列。Parquet 规范还定义统计信息、page index 和 Bloom filter 供跳过不可能匹配的数据。[Apache Parquet 文件布局](https://parquet.apache.org/docs/file-format/)、[Apache Parquet Bloom filter](https://parquet.apache.org/docs/file-format/bloomfilter/)
- 稳定事件段已经包含交易核心需要的 record header、payload、连续分片序号和 CRC。顺序重放直接验证并投递这些记录，不需要先生成列，再重新构造领域事件。

因此：

- `SourceArchive` 保留原始接入日志和分片决策日志的原格式。
- `ReplayDataset` 是不可变清单和范围索引，不是“必须再转一次格式”的同义词。首版优先引用已经封存的事件段；只有小文件数量或 seek 成本经测量成为问题时，才生成内容等价、次序不变的合并事件段。
- `ResearchDataset` 才把选定字段投影为 Parquet。它可随解析器或转换版本重建，不成为交易事实的新权威来源。

这也避免双重校验：权威 replay 继续使用事件段原有 CRC 和连续序号；Parquet 文件使用自己的格式校验并由 `DatasetManifest` 保存内容哈希。

## 2. Parquet：选择为研究列式文件，不选择为权威 replay

### 2.1 适合 `scan` 的原因

DuckDB 官方 Parquet reader 会自动把投影和过滤条件推入扫描，并利用 zonemap 跳过 row group；Hive 目录分区上的条件还可直接跳过文件。[DuckDB Parquet 读取](https://duckdb.org/docs/stable/data/parquet/overview)、[DuckDB Hive partitioning](https://duckdb.org/docs/current/data/partitioning/hive_partitioning)

首版按已确认逻辑分区生成不可变 Parquet：

```text
<sensitivity>/<data_class>/<venue>/<product>/<instrument>/<utc_date>/<utc_hour?>/
```

- L2、MarketTrade 等高流量事件按小时；1 秒、1 分钟序列按日。
- 私有数据在路径最上层先按权限域隔离。
- catalog 把明确的文件列表交给 DuckDB，不让查询通过递归 glob 或目录 listing 猜测某个数据集版本。
- 文件内优先按时间及稳定序号写入，使常见时间过滤的 min/max 范围更紧；DuckDB 官方说明排序可收紧 row-group 统计范围并改善选择性扫描。[DuckDB Parquet tips](https://duckdb.org/docs/current/data/parquet/tips)
- 保持既定的压缩后 256 MiB–1 GiB 文件目标。row-group 大小不能照抄通用经验值：较小 row group 增加并行度和跳过精度，较大 row group 通常利于压缩，必须用实际 schema 定型。

首版默认评估 ZSTD 压缩，但最终 codec、压缩级别和 row-group 大小由原型决定并写入 `TransformationManifest`。不能把某个库的默认值当成数据契约。

### 2.2 不适合承担权威 replay 的原因

Parquet 是列式表格式，不是本项目版本化事件协议。即使行在单个文件内按 `ReplayOrder` 写入：

- 跨文件顺序仍须由 manifest 的首尾序号决定，不能依赖文件名或目录枚举。
- SQL 中经过 join、group 或其他算子后不保证保留输入顺序；DuckDB 虽默认让直接 Parquet reader 保持插入顺序，也明确列出了不保序的算子和配置开关。[DuckDB order preservation](https://duckdb.org/docs/lts/sql/dialect/order_preservation)
- Parquet replay 必须解压列、处理 null/字典表示，再重新构造交易核心事件；直接事件段没有这层转换。
- 列式 schema 演进与交易事件 schema 演进会形成两个需要一致维护的 replay 解码路径。

因此 `replay` 不调用 DuckDB，也不通过 `ORDER BY replay_order` 修补物理布局。它按 manifest 的段范围顺序打开文件，检查首尾序号、内容哈希和连续性，然后把原事件记录送入核心。

## 3. Arrow IPC：保留为交换格式，不增加一套长期存储

Arrow 的列式内存格式支持常数时间随机访问、SIMD 友好布局和可重定位的 zero-copy buffer。IPC stream 是必须从头处理的 record-batch 消息流；IPC file 增加 footer 和 batch offset，可随机访问及内存映射。[Arrow Columnar Format](https://arrow.apache.org/docs/format/Columnar.html)、[Arrow IPC C++ API](https://arrow.apache.org/docs/cpp/api/ipc.html)

这些能力适合：

- DuckDB、Python 研究代码和其他进程之间交换查询结果；
- 已经物化到本地的短寿命批次使用 memory map；
- 避免把查询结果先转 CSV 或 Python 对象。

它不替代首版 Parquet：

- IPC 的主要价值是低转换开销和内存映射；Parquet 的主要价值是长期压缩、列统计和选择性扫描。
- IPC file 必须正常 `Close()` 写入 footer，否则文件无效；它仍需要外部 manifest 才能原子发布和版本化。[Arrow IPC C++ API](https://arrow.apache.org/docs/cpp/api/ipc.html)
- 再永久保存一套 Arrow IPC 副本会违反最低复杂度，并扩大单副本磁盘占用。

结论是只在实际进程接口需要时使用 Arrow IPC/C Data Interface，不预先生成“Arrow 热层副本”。若将来基准证明某个固定研究数据集反复扫描时 IPC 明显改善延迟，再把它作为可回收缓存，而不是权威数据。

## 4. DuckDB：选择为内嵌查询引擎，不选择为共享存储

DuckDB 是进程内数据库，可直接扫描多个 Parquet 文件，并在文件内并行处理、自动做 projection/filter pushdown。[DuckDB client overview](https://duckdb.org/docs/current/clients/overview)、[DuckDB 查询 Parquet](https://duckdb.org/docs/current/guides/file_formats/query_parquet)

首版运行方式：

- 每个交互研究会话或批量 worker 在自己的进程中使用 DuckDB。
- catalog 先把 `DatasetRef` 解析为固定 manifest 和文件列表；同一任务期间不再次解析 `latest`。
- DuckDB 使用内存数据库或临时工作区直接扫描 Parquet；长期数据不导入 `.duckdb` 文件。
- 查询必须显式带 `DatasetRef` 和契约要求的时间范围或唯一标识。
- 4 个交互会话及批处理 worker 由外部作业调度器限制 CPU、内存和 I/O；DuckDB 不负责全局资源公平。

DuckDB 官方并发模型说明：单进程内支持多个 writer thread；普通读写模式只允许一个写进程，而多个进程只能同时以只读方式打开同一数据库。[DuckDB concurrency](https://duckdb.org/docs/current/connect/concurrency) 本方案根本不让多个任务共享可写 DuckDB 文件，所以绕开了这一限制：它们只共同读取不可变 Parquet。

不选 DuckDB 持久数据库作数据主存，原因是：

- 会把 Parquet 数据复制到第二种物理存储；
- 多进程写入与既定 32 worker 模型不匹配；
- `DatasetManifest`、内容寻址和稳定 `DatasetRef` 已经定义版本边界，无需再把数据塞入另一份事务数据库。

## 5. Polars：允许研究者使用，但不是平台必需组件

Polars 的 lazy `scan_parquet` 能把 predicate/projection 下推到扫描层，也能用 Parquet 统计和 Hive 分区做裁剪。[Polars `scan_parquet`](https://docs.pola.rs/api/python/stable/reference/api/polars.scan_parquet.html)、[Polars lazy optimizations](https://docs.pola.rs/user-guide/lazy/optimizations/)

它与 DuckDB 的能力重叠但接口风格不同。首版不在数据模块中再抽象一个“通用查询引擎接口”，也不要求每个研究任务经过 Polars：

- SQL、审计定位和多表分析统一以 DuckDB 作为资格基线；
- 策略研究代码可直接用 Polars 读取同一个 manifest 文件列表；
- Polars 结果不改变 catalog、发布或 replay 语义。

只有真实研究负载证明 Polars 是必需运行依赖时，才把精确版本纳入生产资格；现在无需把可选 Python 库提升为系统组件。

## 6. SQLite catalog：最小事务边界

SQLite 只保存小型、强关系的元数据：

- `DatasetRef`、不可变 `DatasetManifest` 和状态；
- partition 的路径、首尾时间／序号、行数、大小、内容哈希和质量；
- 上游引用、`TransformationManifest`、`RunArtifact` 引用；
- 可变的推荐版本指针及延迟删除状态。

数据文件、事件 payload、因子列和大规模统计不进入 SQLite。

### 6.1 并发模型

使用 WAL 模式：

- WAL 允许 reader 与 writer 并行，但同一时刻仍只有一个 writer；
- reader 在事务开始时固定自己的 end mark，得到一致快照；
- 所有连接必须位于同一主机，WAL 不支持网络文件系统。[SQLite WAL](https://www.sqlite.org/wal.html)

这正好匹配首版：

- 只有一个 Dataset Publisher 写 catalog；
- 研究任务用短事务解析 manifest 后立即结束 SQLite 事务，再读取不可变文件；
- 不允许研究任务持有 SQLite read transaction 跨越长时间 Parquet scan，避免 checkpoint starvation；
- `busy_timeout` 只处理短暂 checkpoint/write 竞争，不能掩盖第二个 publisher。

使用 `PRAGMA synchronous=FULL`，因为 SQLite 官方说明 WAL + FULL 才在断电下提供 ACID；NORMAL 仍保持一致性，但最近提交可能在断电后回滚。[SQLite `synchronous`](https://www.sqlite.org/pragma.html#pragma_synchronous)

**SQLite 最低版本必须是 3.51.3，或带官方修复的 3.50.7／3.44.6。** SQLite 官方披露，3.7.0 至 3.51.2 的 WAL 在两个连接并发写或 checkpoint 的极窄时序下可能触发 WAL-reset corruption；3.51.3 修复，并回移到 3.50.7 和 3.44.6。[SQLite WAL-reset bug](https://www.sqlite.org/wal.html#the_wal_reset_bug)

### 6.2 原子发布流程

文件系统和 SQLite 不能组成一个真正的跨系统事务。首版用“数据先耐久、引用后可见”得到无悬空引用的安全结果：

1. 在最终目录同一文件系统内的 staging 路径写全部文件。
2. 完成 schema、内容哈希、序号、缺口、重复和引用检查。
3. `fsync` 每个文件；把 staging 目录 rename 到唯一、不可变的最终路径；`fsync` 相关目录。
4. 在一个 SQLite 事务中插入完整 manifest、partition、血缘，并更新可变推荐指针。
5. 事务提交成功后 `DatasetRef` 才可被发现。

POSIX 要求目录修改（包括 rename）原子且可串行化；但原子不等于断电耐久，Linux 还要求显式同步文件和目录。[POSIX directory operations](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap04.html#tag_04_04)、[Linux `fsync(2)`](https://man7.org/linux/man-pages/man2/fsync.2.html)

崩溃结果只有：

- 第 4 步之前崩溃：可能留下 staging 或最终孤儿目录，但 catalog 不可见；延迟 GC 可清理。
- 第 4 步提交后崩溃：catalog 引用的数据文件已先完成耐久化。
- 不会出现 catalog 已发布但数据仍在半写状态。

不覆盖已发布目录，不用同名目录替换，不尝试原子交换多个非空目录。每个物理版本使用唯一内容地址；稳定 `DatasetRef` 永不改指向。

## 7. 本地 POSIX 文件系统与对象存储

### 7.1 首版选择本地文件系统

本地文件系统满足当前已接受的单节点一副本边界：

- 数据就在运行 DuckDB 和 replay worker 的节点上，没有对象 API、网络、TLS 和本地缓存层；
- 同文件系统 rename 提供简单的原子可见性，文件和目录可 `fsync`；
- 顺序 replay 可直接使用普通文件读取、readahead 和后续资格测试确定的 I/O 路径；
- SQLite WAL 也要求同主机共享内存语义，不适合把 catalog 放到网络文件系统。

文件系统类型、mount 参数、NVMe 型号、readahead 和直接 I/O现在不写死；它们由同一台研究节点上的崩溃测试与吞吐基准资格化。第一版不承诺单盘或单节点故障恢复，这与既定 `1 副本 / 1 故障域` 完全一致。

### 7.2 首版拒绝自建 S3-compatible object store

Amazon S3 对成功 PUT/DELETE 后的 GET/LIST提供强一致性，单个 key 更新原子。[Amazon S3 consistency](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel) 但这不等于多对象数据集的一次事务；完整数据集仍要依赖 manifest/catalog 指针来发布。这一点是从官方“单个 key 原子”边界作出的推论。

在单机一副本上部署 S3-compatible 服务不会创造新的故障域，却会增加：

- 一个常驻服务及其升级、凭证、端口、监控和恢复；
- POSIX 文件与对象 API 间的转换；
- 本地查询的 HTTP 路径和缓存；
- 与 SQLite/catalog 重叠的可见性处理。

因此首版不部署 MinIO 或其他 S3-compatible 服务。未来只有在增加独立存储节点、跨机器 compute、容量池或远程冷层时，才把物理后端切换到对象存储；`DatasetRef`/manifest 已经是这个切换接缝，不需要现在建立自研存储抽象框架。

## 8. 拒绝首版 Iceberg、Delta Lake 和 lakeFS

### Iceberg

Iceberg 用 metadata file、manifest list 和 snapshot 跟踪数据文件，通过原子替换当前 metadata 指针实现 serializable isolation 和 snapshot reads。规范还指出 file-system table commit 方案已弃用且在对象存储及本地文件系统上不安全；推荐由 metastore/database 提供 compare-and-swap。[Apache Iceberg spec](https://iceberg.apache.org/spec/)

这能解决大规模多 writer 表、schema/partition 演进和行级删除，但首版数据集是单 publisher、不可变新版本、无原地更新。引入 Iceberg 会增加 catalog 协议、manifest 层和兼容性矩阵，却不替代项目自己的 `DatasetManifest`、`ReplayOrder`、权限域和 lineage，因此拒绝。

### Delta Lake

Delta 以 `_delta_log` 中连续编号的 JSON commit 作为表级原子单位，支持多 writer ACID、snapshot isolation、checkpoint 和增量 tail。[Delta Transaction Log Protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md)

首版不对已发布 Parquet 做 update/delete，也不需要多个 writer 竞争一个表版本。项目已经要求更正发布为新 DatasetRef，SQLite 事务可以原子发布整个 manifest。再叠加 Delta log 只会形成第二套版本、checkpoint 和 GC 规则，因此拒绝。

### lakeFS

lakeFS 在对象存储之上提供 Git 式 branch/commit；其架构还需要 lakeFS server、底层对象存储和 PostgreSQL、DynamoDB、CosmosDB 或 Redis-compatible 元数据存储。[lakeFS architecture](https://docs.lakefs.io/dev/understand/architecture/)、[lakeFS data structure](https://docs.lakefs.io/latest/understand/data-structure/)

当前没有多人分支、合并或跨环境对象湖需求。增加 lakeFS 会把单机方案变成至少三类服务，明显超过问题规模，因此拒绝。

这三个拒绝不是永久技术禁令。只有出现下列已测需求之一时才重新评估：多个独立 publisher、远程对象存储、多节点计算、表级 update/delete、跨团队 branch/merge，或 SQLite catalog 已成为实测瓶颈。

## 9. 16M events/s 与必须完成的原型

已测事件平均编码大小为 115.20 B。8 路合计 16M events/s 对应至少：

```text
16,000,000 × 115.20 B = 1,843,200,000 B/s ≈ 1.72 GiB/s
```

这还未计文件读取放大、校验、解压、对象构造和 BookCheckpoint seek。当前单流恢复扫描中位数 2.08M events/s，八路并行若想达到目标，不能假设线性扩展；共享 NVMe 带宽、CPU、页缓存、内存带宽和调度都会竞争。

因此以下结论必须由 Linux 研究节点原型验证，不能从格式文档推导：

### 9.1 replay 资格

用真实事件类型和大小分布，同时启动 8 个独立 replay reader：

- 每路固定不同文件和 CPU，持续至少 10 分钟；
- 打开现有 header/payload CRC、序号连续性、schema dispatch 和交易核心事件构造；
- 测每路最低/中位 events/s、总吞吐、CPU、NVMe 吞吐、major/minor fault、P95/P99 feed stall；
- 冷页缓存和热页缓存分别测试；
- 在 BookCheckpoint seek 后测试局部 replay，而不只测试从文件头线性读；
- 验证任何 gap、重复、损坏或 manifest 范围不一致均 fail closed。

通过条件是 8 路同时持续各自至少 2M events/s，而不是八路平均值掩盖慢流。现有 Windows 单流结果不能豁免此测试。

### 9.2 Parquet 资格

用同一份事件投影比较：

- ZSTD 与 Snappy；
- 至少三种 row-group 大小；
- 契约内的小时/日分区和 256 MiB–1 GiB 文件；
- DuckDB 的单 Instrument 日内扫描、一年分钟序列、订单 ID 定位和 4 会话并发；
- 生成吞吐是否能在 SourceArchive 分段封存后 P95 60 秒内完成 catalog 发布；
- 字段/分区 pushdown 是否真的减少读取 bytes 和 row groups。

可以把 Parquet 事件流作为对照跑 8 × 2M events/s，但即使通过，也只说明未来可简化物理副本；在它同时证明确定性、整数/比例尺无损、schema 演进和损坏检测之前，不替换稳定事件 replay。

### 9.3 catalog 与崩溃资格

- 1 publisher + 16 个短读连接，测 manifest/lineage 查询 P95；
- 在文件 `fsync`、directory rename、directory `fsync`、SQLite commit 前后逐点 kill/power-failure 模拟；
- 每次恢复只允许发现完整旧版本或完整新版本；孤儿文件可回收，已发布引用不得缺文件；
- 持续 4 个研究会话时验证 reader 及时结束 catalog transaction，WAL checkpoint 不饥饿；
- 验证固定 `DatasetRef` 在推荐指针变化和 GC 扫描期间仍返回原 manifest。

## 10. 首版具体约束

1. SourceArchive、ReplayDataset 和 ResearchDataset 不共享“一个格式解决全部问题”的假设。
2. 只有 Dataset Publisher 能写最终数据目录和 SQLite catalog。
3. 所有数据文件写到唯一 staging 路径；校验、同步、rename 后才允许 catalog commit。
4. SQLite 使用 WAL、`synchronous=FULL`，版本不低于 3.51.3，或使用官方修复 backport 3.50.7／3.44.6。
5. 研究 reader 只能读取 manifest 显式列出的不可变文件；禁止扫描 staging 或用目录 listing 推导数据集完整性。
6. `scan` 的普通结果不隐式承诺顺序；需要顺序时显式指定字段。
7. `replay` 不走 SQL，必须按 manifest 范围与 `ReplayOrder` 顺序读取稳定事件段。
8. DuckDB 是每个任务的内嵌计算库，不是共享数据库服务。
9. Arrow IPC 是交换格式，Polars 是可选研究库；两者都不是 catalog 或权威存储。
10. 第一版不部署对象存储、Iceberg、Delta、lakeFS、分布式查询层或通用 SQL 网关。

## 11. 何时升级

保持当前组合，直到出现实测而不是预想的瓶颈：

| 触发条件 | 再评估方向 |
|---|---|
| 多个独立发布者必须并发提交同一数据集 | Iceberg/Delta 或具有 compare-and-swap 的服务型 catalog |
| compute 与存储必须跨机器扩展 | S3-compatible/object storage，并保留 manifest 原子指针 |
| 研究需要 branch、merge、隔离试验数据湖 | lakeFS |
| SQLite 的单 writer 或 catalog 查询成为已测瓶颈 | PostgreSQL 等服务型 catalog |
| 反复读取的固定列集受 Parquet 解压限制 | 可回收 Arrow IPC 热缓存 |
| 原始段数量使 replay seek/list 成本不达标 | 使用同一稳定编码做确定性段合并，不先更换格式 |

在这些触发条件出现前，Parquet + 稳定事件段 + SQLite + DuckDB + 本地文件系统已经覆盖全部确认契约，额外 lakehouse 组件只会增加故障面。

## 12. 已知风险

| 风险 | 首版处理 |
|---|---|
| 单节点、单盘或文件系统损坏会永久丢失数据 | 已由数据契约明确接受；校验只能发现损坏，不能修复 |
| 八路 replay 争抢 NVMe、内存带宽或 CPU，未达到 16M events/s | 上线前执行第 9.1 节真实并发资格测试；不以单流结果外推 |
| Parquet 压缩或 row-group 参数使发布新鲜度、交互延迟不达标 | 用真实 schema 比较 ZSTD/Snappy 和 row-group；参数写入 manifest，不写死在接口 |
| 文件 rename 已可见但 SQLite 尚未提交时崩溃 | 形成不可见孤儿，由延迟 GC 清理；禁止目录 listing 绕过 catalog |
| SQLite 长 reader 阻塞 WAL checkpoint | catalog 事务只解析 manifest，文件扫描前结束事务，并监测 WAL 大小 |
| DuckDB/Polars 升级改变类型、顺序或优化行为 | replay 不依赖它们；研究资格固定版本并以结果哈希、整数/比例尺测试验证 |
| SQLite WAL 历史 corruption 缺陷 | 只允许 3.51.3+ 或官方修复 backport |
