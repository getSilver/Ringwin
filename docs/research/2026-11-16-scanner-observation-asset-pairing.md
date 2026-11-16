# 扫描观察资产关联核对

日期：2026-11-16。范围：设置驱动扫描票 06；这是只读观察关联，不是核心资产注册或交易批准。

## 来源与解释

- [Hyperliquid 合约规格](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/contract-specifications)：默认标准加密永续每单位对应一个标的现货单位，通常以 USDT 计价、USDC 结算；HYPE、PURR 指数以 USDC 计价。计价不能由保证金币种推断。
- [Hyperliquid 价格指数](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/robust-price-indices)：指数使用中心化市场，mark 的组成包括 OKX。价格关联不证明提现资产可互换、USDT 与 USDC 等价或交易盈利。
- [Hyperliquid 入门](https://hyperliquid.gitbook.io/hyperliquid-docs/onboarding/how-to-start-trading)：区分 BTC 所在 Bitcoin、ETH 所在 Ethereum，以及永续头寸与持有现货；[OKX Ethereum](https://www.okx.com/price/ethereum-eth) 明确 ETH 为 Ethereum 原生 Ether，并列出 ETH/USDT 与 ETH/USDC。
- 完整 meta 的 coin 没有通用跨所链／代币身份。仅同名无法可靠关联任意代币、包装资产、缩放标的或第三方部署市场。[Asset IDs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids) 的 universe 下标不是经济资产身份。

## 本次采用的边界

用户确认在 06 补足有协议依据的资产关联。结合上述来源，内部明确绑定主网默认标准永续的 BTC 到 Bitcoin 原生资产、ETH 到 Ethereum 原生资产，采用与 OKX 对应观察资产相同的固定 18 位观察单位。USDT 价格与 USDC 结算分别关联。这是经过逐项核对的来源绑定，不是任意字符串同名合并。

InstrumentIdentity、观察来源、环境、规则摘要和 native 会话保持独立。Testnet 保留独立资产空间。未知 coin、WETH 等包装标签、HIP-3 与现货包装资产不自动继承关联。

目录仍接纳全部通过协议和单位校验的品种。两个已确认基础资产只限制跨所关联，不限制市场发现，也不要求用户登记市场、tick、lot 或身份文件。扩大配对覆盖需要额外资产依据；本次没有取得全部同名币的配对资格。

旧缓存恢复后仍默认停止、不联网。显式发现若改变资产关联，范围按原代码在对应来源空间重绑、版本推进、持久化并撤销旧输入后预热。核心 AssetDefinition、余额、InstrumentRules 激活和交易权限不随该关联变更。

## 证据限制

官方文档核对仅说明协议语义。内部验收仅在公共 transport 输入合成协议字节，实际执行 Zig 解码、RawIngress、规范投影和 Python 扫描。没有在线行情新鲜度、连续运行、经济或生产资格。
