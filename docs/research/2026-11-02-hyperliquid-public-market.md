# Hyperliquid 04 公共行情离线实现

范围为 [04](../../.scratch/hyperliquid-adapter/issues/04-public-market-feed.md) 及识别出的
[MarketTrade 前置](../../.scratch/hyperliquid-adapter/issues/04a-market-trade-contract.md)。协议依据沿用
[01 合同](2026-11-02-hyperliquid-protocol-contract.md)、固定来源与公开样本；本次补核对官方
[WS 结构](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions)。
现有来源样本身份见 `src/testing/fixtures/hyperliquid/sources.json`，不改写历史采集结果。

## 实现边界

- `HyperliquidMarketFeed` 每实例绑定一个已配置 Instrument，独立于账户与凭证；多个实例互不等待。
  Runtime 注入完整帧、接收时间、连接 epoch 与同步 RawSink。Adapter 不做 I/O、睡眠或重试；
  订阅请求最多 book/trades/context 三条，运输、共享 IP 限流及调度由 07 接线。
- `RawRecord` 记录 Venue、环境、稳定 raw stream、session、instrument、epoch、消息路由、
  时钟、长度和 SHA-256；同步捕获成功后才解码。RawSink 必须持久提交再返回序号；测试 sink
  只证明调用顺序与回放，不代表平台断电持久性资格。
  RawSink 回调必须有界且不执行阻塞 I/O；尚未获得持久确认时返回 Backpressure，由 runtime
  保留输入并处理失效/重订阅，不能在 Adapter 线程等待磁盘或网络。
- 元数据只发布 `InstrumentDefinitionObserved`，不注册资产、不激活规则或授权交易。
  永续按 universe 下标/name 与 collateralToken 绑定；现货按 pair index、base/quote token index
  和 tokenId 绑定。包装资产经济身份与交易批准仍归配置。元数据选中记录/相关 token 的
  内容变化保守撤销资格。Binding 必填、非零的 `expected_metadata_digest` 由已批准规则配置提供，
  Adapter 不以首帧自选基线；重启仍比对同一预期值。永续摘要依次包含选中 universe row、
  其引用的完整 margin table；缺表或重复匹配拒绝。现货为选中 pair，再按来源数组顺序包含
  base/quote token 记录。各值以 `std.json.Stringify` 的紧凑 JSON UTF-8 字节依次进入 SHA-256；
  字段/记录排列变化也可能触发保守失效。新规则需要外部批准新版本和摘要并配置新实例；
  摘要不证明 margin tier 已进入核心风控计算。
- book 为完整有限快照，最多验证每侧 20 档，保存 8 档及截断。尾部同样校验价格/数量、
  排序和订单数；无数量、缺侧、交叉或不精确值均撤销资格。无 delta、无 Venue 前序链，
  捕获序号与 epoch 显式携带。源时间相同且内容相同 no-op，冲突或迟到失败关闭。
- 连接/超时/坏帧/规则变化撤销资格；重订阅要求更大 epoch 与不倒退的时间屏障，新书源时间
  不得早于屏障。Runtime 从 durable 高水位分配 epoch，保留每帧原接收时钟与 incarnation，
  不给旧排队帧重新标记。公开 `poll` 用单调时钟过期；驱动必须在消费前推进 timer。
  新订阅首个结构合法且仍在年龄范围内的缓存书若早于订阅屏障，仅报告
  `AwaitingFreshSnapshot` 并维持 gap，保留订阅等待同 epoch 的合格新书；不推进屏障追逐缓存帧。
  畸形书或已健康后的迟到仍要求新订阅。
- 输出单批有界，普通帧预留一个安全事件位置。背压时输入不被消费，调用方保留帧重试；
  超时/断连可在已有输出后追加 gap，最终状态不会由旧排队快照恢复。停机先 drain，健康状态
  还会产生必须 drain 的 gap。捕获失败或超硬帧边界仅发本地安全失效，raw evidence 为 absent
  的零引用，不伪造原文；这些故障由规范日志恢复，不能声称有不存在的 raw 响应可回放。
- 每帧最多 30 个 trade/费率记录，最大解码帧 1 MiB；超限拒绝并 gap，不能拿局部处理冒充完整。
  公共 trade 键绑定 Instrument/time/tid，方向显式 B/A，帧内及跨帧重复去重、矛盾拒绝；
  有界窗口保存 256 个身份，窗口外未知旧成交失败关闭，不重新输出为新成交。
- `activeAssetCtx` 的 mark/oracle 分别映射，源时间 absent，不用 mid 或相互回退；
  ctx 没有资金费所属时点，不填造下一结算时点。费率来自带真实时间的 `fundingHistory`，
  精确 ppm 不可表达时拒绝；不输出资金流水或预测费率资格。

## 共享合同与影响

新增 Venue 中立 MarketTrade，只有规范品种、稳定身份、价格/数量、方向和源时间，不带账户
归属。核心验证品种、规则、作用域和时间；事件进稳定日志及 ingress digest，不写 OMS 或经济
账本。Host type 8/schema 1 使用独立 96-byte 小端负载：instrument[0:16]、trade identity[16:32]、
rules version[32:40]、ticks[40:56]、lots[56:72]、source time[72:80]、side[80]（0 buy/1 sell），
其余必须零。Zig 与 Python 都严格校验；真实策略是否订阅/消费仍由其自身合同决定。

canonical 20 / codec 15 / journal 52 / state 56 / registry 50；native manifest 同步。
不增加投影驻留布局，StateDigestV15 和账户协调快照 19 保持；旧持久格式精确拒绝，无迁移。
影响限于通用事件/codec/核心验证/Host 编解码、版本注册、公共 Adapter、正式入口和离线编排。
既有 Venue 不新增能力声明或发送路径。

## 证据边界

测试覆盖公开接缝、官方 BTC/现货元数据、合法/非法深度、截断尾部、重复/冲突、错 session、
背压、超时、捕获失败、规则变化、隔离、RawIngress 回放，以及 TradingShard 稳定应用、
Host batch、规范日志和快照加尾部恢复。实际运行结果记录在 04；没有网络连接、真实订阅、
凭证读取或在线交易。本票不提供 maker 排队/成交概率、Testnet 下单或生产资格。
