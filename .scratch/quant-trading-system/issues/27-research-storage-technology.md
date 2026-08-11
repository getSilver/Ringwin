# 选择研究数据存储与查询技术

Type: research
Status: resolved
Blocked by: 18
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

在已确认的数据保留、查询和并发契约下，哪些列式文件、对象存储、目录、查询引擎及数据版本方案能以最低复杂度满足研究和回测需求？

## Answer

完整一手资料、候选比较和风险分析见[研究数据存储与查询技术调查](../research/27-research-storage-technology.md)。

### 首版技术组合

| 职责 | 选择 | 边界 |
|---|---|---|
| SourceArchive | 既有稳定版本化二进制事件段 | 保持原始权威事实，不转换为 Parquet 后取代原日志 |
| ReplayDataset | DatasetManifest 引用的稳定事件段 | 专用顺序读取器按 ReplayOrder 重放，不经过 SQL、DuckDB 或 DataFrame |
| ResearchDataset | 不可变 Apache Parquet | 用于 scan、聚合、特征和研究，不承担权威事件重放 |
| 物理存储 | Linux 本地 POSIX 文件系统 | staging 与最终目录位于同一文件系统；接受既定 1 副本/1 故障域风险 |
| 目录和血缘 | SQLite WAL catalog | 只有 Dataset Publisher 写；reader 用短事务解析 DatasetRef 后直接读取文件 |
| 查询引擎 | 每个研究进程内嵌 DuckDB | 直接扫描 manifest 明确列出的 Parquet，不建立持久共享 DuckDB 数据库或 SQL 服务 |
| Python 互操作 | Arrow 内存模型按需使用 | Arrow IPC 只用于结果或进程交换，不生成长期权威副本 |

scan 和 replay 使用不同物理表示是有意设计：Parquet 的列裁剪、过滤下推和 row-group 统计适合交互研究；稳定事件段已经包含核心可消费的事件头、payload、CRC 和连续序号，更适合确定性顺序重放。第一版不维护第二套 Parquet-to-core 权威解码路径。

### Parquet 数据布局

- 逻辑分区继续遵守既定的权限域、数据类别、Venue、产品、Instrument 和 UTC 时间层级；L2 和 MarketTrade 等高流量事件按小时，1 秒和 1 分钟序列按日。
- 私有数据先按权限域物理隔离；公共和私有数据不得进入同一文件。
- catalog 把 manifest 中的明确文件列表交给 DuckDB，不允许 reader 通过递归 glob 或目录 listing 推导数据集版本。
- 文件内优先按时间和稳定序号组织，以改善 row-group min/max 跳过。
- 保持压缩后 256 MiB–1 GiB 文件目标；ZSTD、Snappy、压缩级别和 row-group 大小必须用真实 schema 比较后写入 TransformationManifest，不把库默认值当作合同。
- Price、Quantity、Money、Rate、序号和时间戳保持整数、比例尺和单位，不因进入 Parquet 或 DuckDB 转成 f64。

### ReplayDataset

- ReplayDataset 首版优先直接引用已封存稳定事件段；只有实测小文件或 seek 成本成为瓶颈时，才用同一编码确定性合并分段。
- manifest 明确记录每段的首尾 ReplayOrder、时间、序号、内容哈希、缺口和质量；跨文件次序不能依赖文件名或目录枚举。
- replay reader 顺序打开 manifest 指定的事件段，验证内容哈希、CRC 和序号连续性，再把原事件记录交给交易核心。
- BookCheckpoint 只负责定位起点，后续事件仍按 ReplayOrder 应用。
- 普通 scan 不承诺隐式顺序；需要排序的研究查询必须显式指定字段。

### DuckDB 与并发

- 每个交互会话或批量 worker 使用自己的内嵌 DuckDB 实例和临时工作区，直接只读不可变 Parquet。
- 不把数据导入共享 `.duckdb` 文件，避开 DuckDB 不原生支持多进程并发写同一数据库的限制。
- DatasetRef 在任务开始时解析并固定为一个 manifest 和文件列表；同一任务期间不再次解析 latest。
- 既定的 4 个交互会话、8 条 replay 流和最多 32 个批量 worker 由外部作业调度与资源限制执行，DuckDB 不负责全局公平性。
- Polars 可以由研究代码直接读取相同 manifest 文件列表，但不是平台必需组件，也不为它增加通用查询引擎接口。

### SQLite catalog

SQLite 只保存 DatasetRef、DatasetManifest、partition 摘要、质量、血缘、引用、推荐版本指针和延迟删除状态；事件 payload、因子列和大规模统计不进入 SQLite。

- 使用 WAL 与 `synchronous=FULL`，只允许一个 Dataset Publisher 写。
- reader 只在解析 manifest 时持有短 read transaction；开始 Parquet scan 前必须结束事务，避免 WAL checkpoint starvation。
- SQLite 文件必须位于本地主机文件系统，禁止通过网络文件系统共享 WAL。
- 最低版本为 3.51.3，或包含官方 WAL-reset 修复的 3.50.7／3.44.6；更早未修复版本不得作为 catalog。
- busy timeout 只处理短暂 writer/checkpoint 竞争，不能用于掩盖第二个 publisher。
- SQLite catalog 是可重建目录索引；不可变 manifest 和数据文件仍保持自身内容身份。

### 原子发布

文件系统和 SQLite 不伪装成跨系统事务。采用“数据先耐久，引用后可见”：

1. 在最终目录同一文件系统的唯一 staging 路径写完全部文件。
2. 验证 schema、内容哈希、序号、缺口、重复和引用。
3. fsync 文件，将 staging rename 到唯一不可变最终路径，再 fsync 相关目录。
4. 在一个 SQLite 事务中写入完整 manifest、partition、血缘并更新推荐指针。
5. 只有 SQLite commit 成功后，DatasetRef 才能被目录发现。

catalog commit 前崩溃最多留下不可见孤儿目录，由延迟 GC 清理；commit 后引用的数据已经先完成耐久化。已发布目录和稳定 DatasetRef 永不覆盖或改指向。

### 数据版本

- 每个物理版本使用唯一内容地址，由 DatasetManifest 固定文件、范围、schema、质量、血缘和哈希。
- 稳定 DatasetRef 永远指向原 manifest；latest 只是在任务开始时解析一次的可变推荐指针。
- 更正、重解析、重分区和 schema 变化都发布新 DatasetRef，不更新原 Parquet 或事件段。
- TransformationManifest 固定转换构建、参数、类型、舍入、压缩、row-group、上游和验证结果。
- RetentionPolicy 和引用图由 SQLite catalog 加速查询，但删除仍受不可变 manifest 引用保护。

### 物理存储与对象存储

首版不部署 MinIO、Ceph 或其他 S3-compatible 服务：

- 当前只有单节点、单副本和单故障域，自建对象服务不能增加已承诺的耐久性。
- 它会额外引入常驻服务、网络、TLS、凭证、缓存和恢复路径。
- 本地 POSIX rename、fsync、普通文件读取及 SQLite WAL 已覆盖首版合同。

DatasetRef 和 DatasetManifest 已经隔离物理路径。只有出现独立存储节点、跨机器计算、容量池或远程冷层需求时，才增加对象存储后端；对象存储发布必须采用不可变对象、manifest-last 和条件更新指针，不能假设目录 rename。

### 首版拒绝项

- **Iceberg**：其 snapshot、manifest 和 catalog 主要解决多 writer、大规模表演进与对象存储提交；与当前单 publisher、不可变 DatasetManifest 重叠。
- **Delta Lake**：其事务日志、MVCC、checkpoint 和 update/delete 语义不符合“更正产生新 DatasetRef”的最小模型。
- **lakeFS**：还需对象存储、服务端和外部元数据存储，远超单节点需求。
- **持久 Arrow IPC 热副本**：增加磁盘和第三种持久格式；只在实测反复扫描收益成立时作为可回收缓存。
- **共享 DuckDB 数据库、ClickHouse、分布式查询层和通用 SQL 网关**：当前并发与查询合同不需要常驻查询服务。

只有多个独立 publisher、跨机器 compute/storage、表级 update/delete、数据湖 branch/merge 或 SQLite 实测成为瓶颈时，才重新评估这些方案。

### 必须原型验证

官方格式能力不能证明本机性能。实现规划前新增生产等价原型，至少验证：

1. **Replay**：真实 schema 下 8 条独立流同时持续各自不少于 2M events/s，合计不少于 16M events/s；打开 CRC、序号、schema dispatch 和核心事件构造，分别测试冷/热页缓存及 BookCheckpoint seek。
2. **Parquet**：比较 ZSTD/Snappy 和至少三种 row-group 大小，验证契约文件尺寸、发布新鲜度、单 Instrument 日内扫描、一年分钟序列、订单 ID 定位和 4 会话并发。
3. **Catalog**：1 publisher + 16 个短 reader 达到元数据 P95，并逐点注入 fsync、rename、目录 fsync 和 SQLite commit 崩溃，恢复后只能发现完整旧版或完整新版。
4. **资源隔离**：32 个批量 worker 运行时，交互 scan 和 8 路 replay 仍满足既定优先级与吞吐合同。

按现有平均 115.20 B/event 计算，16M events/s 仅事件字节就约 1.72 GiB/s，尚未包含校验、解压、对象构造和页缓存竞争；现有 Windows 单流 2.08M events/s 结果不能外推为八流合格。

### 已知风险

- 单节点或文件系统损坏会永久丢失数据；这是已接受的 1 副本/1 故障域风险。
- SQLite WAL 长 reader 会阻碍 checkpoint，因此 catalog transaction 必须短。
- Parquet 参数可能使发布新鲜度或交互延迟失败，必须由真实数据原型定型。
- DuckDB、Polars 或 Parquet 库升级可能改变类型、顺序或优化行为；研究资格必须固定版本并验证结果哈希。
- 八路 replay 可能受 NVMe、CPU、页缓存或内存带宽限制；未通过生产等价原型前不能宣布容量成立。
