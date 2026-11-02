---
status: accepted
date: 2026-11-02
---

# 分离线性逐仓模型与结算资产身份

Hyperliquid 接入需要 USDC 结算的标准线性永续，现有领域与产品合同以 USDT 逐仓命名。用户确认首期限定标准线性永续逐仓：USDT 与 USDC 可共用保证金计算模型，但模型、结算 Asset 和各 Venue 的版本化规则分别绑定。余额、费用、损益及抵押资格按真实资产核算，不按固定 1:1 合并，不授予跨资产抵押能力。

## Considered Options

- 将 USDC 视为 USDT 的别名：改动小，但丢失真实资金单位与经济归属，拒绝。
- 为每种结算币复制保证金模型：区分资产，但重复相同计算语义，不采用。
- 模型与结算资产分别绑定：复用相同计算语义，保留资产隔离与 Venue 规则差异，采用。

## Consequences

全仓、统一/组合保证金及 HIP-3/HIP-4 不属于本次首期范围。现货包装或桥接资产保留独立身份，仅允许配置明确批准的经济敞口配对，不因此获得资产可互换资格。

这是已确认的设计方向，不是实现或交易资格声明。当前 `Product.isolated_linear_usdt` 及相关经济、风险、codec、journal、snapshot、digest 和既有 Venue 路径仍须核对并作为共享合同前置工作验证；不得仅改名称或借用旧持久格式身份宣称已支持。


## 02 共享合同落地（2026-11-02）

`Product.isolated_linear` 与 `native_margin_reconciliation.Model.isolated_linear_v1` 不再绑定币名。
`AccountConfiguration.settlement_asset` 在资金基线建立前固定该账户经济投影的计价资产，
所有已登记和后续 InstrumentRules 必须匹配；现有一个账户投影只支持一种结算资产，混合配置显式拒绝。
USDC 使用独立 AssetDefinition 与 Venue code binding，不替换 USDT，也不赋予包装资产可互换资格。
多账户仍沿 ADR 0017 的独立分区处理；同结算币跨所策略接线归票 07。

风险金额、预留、费用、损益、账本、资金费、原生保证金及协调摘要均绑定真实结算资产。
经济 scalar 字段采用 settlement 名称，旧 micros fixture 准入只保留 USDT 的显式兼容路径；
其他资产必须启用原生 atoms。现有 Venue 依其实际品种/代码解析并校验资产；共享类型支持
USDC 不代表已为任何具体 Venue 登记 USDC 市场或取得运行资格。

InstrumentRules 增加有效数字上限、小数位上限和整数价格例外，精确价格由 tick atoms 与资产尺度计算。
无特殊约束的现有规则保持固定 tick 语义；特殊约束的 price_atomic_scale 必须等于结算资产尺度。
规则在风险准入前与 Gateway 提交前用同一纯校验，拒绝非法/溢出价格，不修改已授权价格或数量。
全仓、统一/组合保证金继续不支持；不新增账户配置 API 透传。

| 影响 | 处理 |
| --- | --- |
| Product / MarginModel 消费者与 fixture | 改为资产中立身份，既有 OKX/Binance/Bybit/Simulated 映射随调用同步 |
| 核心配置、风险、经济、账户协调 | 显式账户结算资产绑定、资产金额隔离和协调摘要拒绝异资产 |
| 价格规则 / registry | 新规则进入稳定输入 codec、快照、配置比较及 digest；恢复执行同样范围校验 |
| 市场投影 / Host / Python | [捕获 epoch 与序号证据](../depth-snapshot-contract.md) 独立于 Venue 前序链，保留覆盖/截断 |
| CanonicalEventCodec | canonical 18 → 19、codec 13 → 14，编码新证据并精确匹配版本 |
| journal / snapshot / registry | journal 50 → 51、state 54 → 55、registry 48 → 49；旧格式失败关闭 |
| digest / 原生 manifest / 协调快照 | StateDigestV14 → V15、manifest 兼容身份更新、协调快照 18 → 19 |
| 固定恢复轨迹 | 先核对经济断言及完整重放一致，再重新捕获新格式摘要 |

不提供旧经济状态自动迁移；历史数据须以匹配 revision/格式读取。共享合同离线证据与
Hyperliquid 签名、实际 Adapter、Testnet 和生产资格分别记录。
