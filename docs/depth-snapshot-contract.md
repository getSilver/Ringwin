# 双边深度快照合同

任务：[02 双边多档快照贯通策略输入](../.scratch/cross-venue-core-interface/issues/02-depth-snapshot.md)。

## 数据与覆盖

`L2BookSnapshot.depth` 是可选的 `BookDepth`，每侧最多 8 档。档位使用整数 price ticks 和可选 quantity lots；Instrument、规则版本与源序列由所属快照绑定，`visible_at_ns` 为捕获的接收 UTC 纳秒。TradingShard 校验它等于规范信封接收时间。档位必须价格为正、数量非负、买价严格递减、卖价严格递增且不交叉，顶部与旧字段一致；非活动尾部必须为零/缺失。缺少一侧、计数越界、规则/品种不一致或 `complete=false` 不提供合格深度。

`bid_count`/`ask_count` 声明各侧可见档位。超过 8 档时保留前 8 档并设置该侧 `*_truncated`，被丢弃尾部仍校验 tick、lots 与排序。`truncated=false` 也只证明给出的价格范围，不能宣称整个交易所订单簿已穷尽。`lots=null` 表示数量未知，`lots=0` 表示可证零量，两者不能互换。

OKX `ingest/replay -> tryDrain` 完成 Venue 私有协议转换。非法转换在返回错误的同时提供有 RawIngress 证据的 gap 事件，调用者必须继续 drain。空侧提供 gap，绝不生成虚假盘口。Binance、Bybit、旧模拟输入仍可提供旧的单档字段，但 `depth=null`，不会取得多档证明；这些 Venue 的深度能力不由本票授予。

## 数量、成本与费用

`market/depth_snapshot.quote` 对 buy 消耗 asks、sell 消耗 bids，按声明覆盖逐档累加。请求量、价格保护必须为正，费用为 `[0, 1_000_000)` ppm。超出覆盖、穿越价格保护或遇到所需档位数量未知返回 `InsufficientDepth`，不外推流动性。数量、价格与累计成本算术溢出返回 `DepthOverflow`。

返回 gross lots、费用后的 base lots，以及 quote tick-lots（price tick × quantity lot）。报价单位转换由调用者绑定该 InstrumentRules 的 tick/lot 原子尺度；函数不声称 tick-lots 已经是结算资产 atoms。手续费向不利于 taker 方向向上取整：基础币费用从 buy 收量扣除、加入 sell 所需支出；报价币费用加入 buy 成本、从 sell 收入扣除。费率/币种由调用者显式传入，不推测交易所账户费率，不以估算覆盖实际 Fill 费用。

## 投影、Host 与重放

Projection 仅接受当前激活规则的快照；迟到或同序列快照不能替换已可见盘口。新规则激活清空旧深度。现有顶部增量会将多档证据清空，Host 在新快照前返回 `MissingDepth`；增量深度与重同步由任务 03 完成。

TradingShard 的旧兼容字段仍要求顶部数量和成对的第二卖档价格/数量；缺失时保守拒绝，不填零。拒绝不完整快照或可见时间不匹配前，先使该 Instrument 的旧盘口失效，通过已有稳定输入与失效事实恢复路径保留 gap，防止 Host 继续使用旧的健康深度。更深档位可保存未知数量，消费到该档时返回不足。

`depthSnapshotInput` 从健康 Projection 构造新的 Host event type **7**（`depth_snapshot`），事件 schema **1**，复用既有 Zig 校验的 batch/pipe。旧的 type 2/3 保留原有 opaque 负载，不隐式升级为深度。深度 Host payload 固定 **704 bytes**，小端编码：

| 偏移 | 字段 |
| --- | --- |
| 0 | Instrument u128 |
| 16 | rules_version u64 |
| 24 | source sequence u64 |
| 32 | visible_at_ns u64 |
| 40, 41 | bid_count / ask_count u8 |
| 42, 43 | bids_truncated / asks_truncated，0 或 1 |
| 44–63 | 保留，必须为零 |
| 64 | 8 个 bid，随后 8 个 ask，每档 40 bytes |

每档：ticks i128（偏移 0），quantity-present u8（16），7 bytes 保留零（17），lots i128（24）。数量缺失时 lots 的编码必须为零。Zig Gateway、IPC 与 Python 验证深度结构；未知类型/版本、错误长度、无效档位与非零保留位失败关闭。Host 源时间未携带时标记 absent，不能把 visible time 当作交易所源时间。Host batch 的 ShardSequence、会话和批次连续性继续由现有协议管理。

捕获的规范事件通过 CanonicalEventCodec 写入稳定日志，Projection 全部深度、数量、截断和可见时间进入 CanonicalStateDigest 与快照。公共测试验证 raw replay、规范编码重放、完整日志恢复与快照加稳定尾恢复的可见输入一致。

## 兼容与资格

Canonical schema **13 → 14**，CanonicalEventCodec **11 → 12**；journal schema **39 → 40**、state schema **43 → 44**、registry **37 → 38**。不重解释旧字节，不提供自动持久格式迁移；旧日志/快照必须由其匹配版本读取，新版本精确匹配失败关闭。部署前的历史迁移不属于本票，运行资格不因此改变。

旧单档消费者继续读取 best bid/ask 等兼容字段；OKX 同时填入第二档 ask 的旧字段。新多档消费者必须要求 `depth != null`。旧 Host 不认识 type 7，应拒绝或不订阅该事件，不能当作已支持。当前 Python Host 新增类型验证与 `decode_depth_snapshot`，仅接收自有 bytes，不新增状态所有权或发送权限。

Python 示例 accumulator 的九字节策略状态重放 schema 不消费深度事件。本票验证核心恢复后的 Host 深度输入一致，不宣称该示例策略或真实策略 checkpoint 恢复通过；策略状态恢复归任务 08/09。

L2 不提供 maker 队列位置、主动成交概率、条件执行、共同准入或收益证据。本票仅覆盖 I1 的快照部分与 V2 的对称覆盖；完整策略、各 Venue 深度、增量、Demo/Testnet/生产及执行模式资格分别验收。
