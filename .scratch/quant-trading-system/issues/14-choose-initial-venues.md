# 选择首批生产交易所

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

第一批生产适配器应支持哪些中心化交易所、账户类型、现货及永续产品，选择标准和明确排除项是什么？

## Answer

### Venue scope and order

- 首批生产候选为 OKX、Binance、Gate.io 和 Bitget；项目以现有账户能够合法使用现货、永续和 API 权限为运营前提。
- 适配器按 `OKX → Binance → Gate.io → Bitget` 顺序完成和验收，不同时开发。
- OKX 作为覆盖 SPOT 与 SWAP 的参考适配器；Binance 用于验证分离的现货/永续接口；Gate.io 用于验证测试网及 SBE 行情；Bitget 最后处理 Classic/UTA 差异。

### Initial product subset

- 普通现货，不包含现货杠杆借贷。
- USDT 本位线性永续。
- 单向净持仓模式。
- 永续首版只支持逐仓保证金。
- 基础订单支持 Limit、Market、GTC、IOC、FOK、Post-only 和 Reduce-only。
- 暂不支持币本位合约、双向持仓、组合保证金、统一跨币种抵押、期权和交易所内置算法单。

### Account and instrument isolation

- 每个 Venue 使用本系统专属生产 ExchangeAccount；可用时优先采用独立子账户。
- 人工交易、跟单、网格工具及其他机器人不得共享该账户；模拟、测试和生产账户完全分离。
- API 密钥不得具有提现权限。
- 适配器发现全部产品元数据，但实盘只允许版本化白名单中的 Instrument。
- 各 Venue 首批验收使用仍同时提供的 BTC/USDT、ETH/USDT 现货和永续；其他 Instrument 完成规格、L2、费用、资金费率及风险验证后通过 ConfigEvent 开放。

### Production admission gate

每个 Venue 必须验证：

1. 官方 API 同时覆盖目标现货和 USDT 线性永续；
2. L2 快照、增量衔接及缺口检测可实现；
3. 私有流提供订单、成交、仓位和余额事实；
4. REST 支持启动及断线后的完整对账；
5. 客户端订单号或等价机制能够安全处理 Unknown 订单；
6. 限流、时间同步、错误语义和测试环境可自动验证。

未通过安全恢复门槛的 Venue 只能作为行情源，不能启用实盘下单。具体能力由[建立交易所适配器能力契约](16-exchange-adapter-capabilities.md)核验。

### Primary sources consulted

- [OKX API v5](https://www.okx.com/docs-v5/en/)
- [Binance developer catalog](https://developers.binance.com/en/docs/catalog)
- [Gate API v4](https://www.gate.com/docs/developers/apiv4/en/)
- [Bitget API](https://www.bitget.com/api-doc/uta/guide)

## Comments

- 2026-07-25：经逐项范围访谈确认并解决。
