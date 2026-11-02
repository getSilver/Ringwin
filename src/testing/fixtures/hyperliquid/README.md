# Hyperliquid 协议样本

用途：ticket 01 的协议合同输入；不是已接入 decoder 的 golden output 或交易资格。
原始 public response 保留下载字节，`sources.json` 记录 URL、完整无秘密请求、UTC、
SHA-256 与来源类别。公共查询只访问 Testnet `/info`，没有账户或凭证输入。

| 文件 | 来源与范围 |
|---|---|
| `meta.json` | 公开 Testnet 标准永续 universe/marginTables/collateralToken 全响应 |
| `spot-meta.json` | 公开 Testnet tokens/pairs 全响应；保留全量以核对索引和未找到的名称；不当作配置 |
| `btc-book.json`, `eth-book.json` | 公开 REST l2Book，有限深度、无源序号的单时点快照 |
| `private-synthetic.json` | 15 个手工合成私有/账户/错误输入及数值向量；地址/oid/tid/hash 是占位，不来自真实账户 |
| `sources.json` | 原始样本及参考资料的内容身份；temporary_capture 是忽略目录里的临时下载，不是可依赖交付文件 |

合成输入包含重复/冲突、fee/rebate/未知 fee Asset、IOC aggregate、Unknown、资金费、
强平/ADL 候选、逐仓和余额。`expected` 是后续行为约束，不代表已经执行这些断言。
`numeric_vectors` 来源为官方 Tick/lot 示例；没有本地价格校验器。
公开无秘密签名哈希向量保留在[签名依据](../../../../docs/research/2026-11-02-hyperliquid-signing-history.md)，
03 才独立验证；fixture 不保存私钥、认证头、可发送签名或已签名请求。

来源日期为查询日期，不是协议版本。后续 decoder 使用样本时应从公开 seam 增加行为验证，
且不得用这些合成记录替代真实部分成交、取消、恢复或 ADL 的在线证据。
