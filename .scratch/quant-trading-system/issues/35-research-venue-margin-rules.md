# 研究首批 Venue 保证金规则与接口矩阵

Type: research
Status: resolved
Blocked by: 28
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

OKX、Binance、Gate.io 和 Bitget 当前对 USDT 线性永续逐仓单向模式分别提供哪些杠杆、风险档位、初始与维持保证金、扣减额、标记价格、强平价格、自动追加保证金、逐仓调整及强平/ADL 接口字段和舍入规则，哪些内容必须由测试环境差分验证？

## Answer

完整官方证据、接口链接、字段映射、文档边界及测试矩阵见[研究记录](../research/35-venue-margin-rules.md)。

### 总体结论

- 四家 Venue 都能提供首版需要的逐仓仓位、杠杆设置、标记价格、预估强平价、保证金调整以及强平/ADL 事实，但风险档位和计算中间量的公开程度不同。
- 不建立跨 Venue 的统一闭式保证金或强平公式。统一层只规定版本化输入/输出契约，每个适配器使用独立 MarginRules 和 testnet 证据。
- 全部经济字段按原始十进制文本解析为定点整数；API schema 中的 float/double 不能进入权威计算。
- 风险档位、用户级系数和合约规则均为动态外部配置，必须按启动、恢复、规则变化和定期刷新重新抓取，以原始响应哈希形成 MarginRules 候选，经验证后通过 ConfigEvent 激活。
- Venue 报告的强平价均按 ReferenceOnly 保存，与本地确定性阈值并列对账，不能覆盖本地风险状态。

### Venue 差异

| Venue | 可直接取得的风险档位 | 关键缺口 |
|---|---|---|
| OKX | `tier/minSz/maxSz/imr/mmr/maxLever` | 逐仓 position 的 `imr` 为空，无独立扣减额及完整中间舍入契约；`liqPx` 明确为估算 |
| Binance | `initialLeverage/notionalFloor/notionalCap/maintMarginRatio/cum`，可有用户级 `notionalCoef` | `cum` 只定义为速算辅助值，完整分段公式、边界和舍入未由 API 闭合 |
| Gate.io | `initial_rate/maintenance_rate/leverage_max/deduction` | 字段最完整，但 `maintenance_rate`、`average_maintenance_rate`、扣减额及档位边界仍须差分 |
| Bitget | `startUnit/endUnit/leverage/keepMarginRate` | 没有档位 IMR、扣减额或强平公式引用的 pre-calculated offset |

- OKX 通过 `tdMode=isolated` 选择逐仓，提供 leverage、position、mark price、margin-balance 及 liquidation/ADL category。
- Binance 通过 symbol margin type 选择逐仓，提供 leverageBracket、account/positionRisk、positionMargin、forceOrders 和 ADL quantile。
- Gate.io 通过 position margin mode/非零 leverage 表达逐仓，提供完整 risk limit tiers、position IM/MM、margin change、liquidates 和 auto_deleverages。
- Bitget 提供 position tier、position/account、set-margin、强平/ADL 通知，并且是本次唯一由官方 API 明确提供 `autoMargin` 查询和 `on/off` 开关的 Venue。

### 自动追加保证金

- Bitget 可把 position 的 `autoMargin` 与 `set-auto-margin` 作为 Confirmed 契约并在启动时验证为 `off`。
- OKX 的 `Auto transfers` 是逐仓交易资金占用/释放模式，不足以证明“亏损后自动扫取可用 USDT”；不能映射成 auto-margin 已关闭。
- Binance 和 Gate.io 当前官方 API 资料没有找到等价的逐仓自动追加查询/开关。
- OKX、Binance、Gate.io 必须以 `Unknown/NotExposed` 建模，直到测试环境和账户配置证据证明目标账户不会自动补充仓位保证金；不能用缺失字段默认 false。

### MarginRules 最小字段

每个 `Venue + Instrument + AccountMode` 版本至少保存：

- 合约乘数、price tick、quantity step 和金额 scale；
- 完整档位区间、边界语义、最大杠杆、IMR 和 MMR；
- Venue 返回的 `cum/deduction`，不存在时显式 absent；
- 标记价格来源及最大陈旧时间；
- 普通 taker fee、强平费用及其适用方式；
- auto-margin capability：`SupportedOn/SupportedOff/NotExposed/Unknown`；
- margin adjustment 最小单位和拒绝边界；
- Venue IM/MM/liquidation-price 字段映射；
- partial liquidation、full liquidation 和 ADL 的分类与幂等身份；
- testnet 证据版本及按 tick/金额定义的对账容差。

### 必须由测试环境差分

四家都必须覆盖：

1. 每个档位的下界前一最小单位、下界、上界前一最小单位和上界。
2. 空仓、已有仓位、同向挂单和反向 reduce-only 挂单的 IM/MM。
3. 杠杆调整在有仓、挂单和跨档时是否隐式搬动保证金、撤单或改变强平价。
4. 逐仓保证金增加/减少的最小单位、拒绝边界及舍入方向。
5. maker rebate、taker fee 和资金费结算前后的 equity、MM 和强平价。
6. 强平、部分强平和 ADL 在 REST、私有 WS、Order、Fill 与账务中的顺序、单位和去重身份。
7. 标记价格展示精度与风险引擎内部精度的差异。
8. auto-margin 的实际账户状态；无法取得可靠证据时保持 Unknown。

每个样本保存去密后的原始请求/响应、私有 WS、合约定义、完整档位、账户模式、测试 RunIdentity、本地定点结果、Venue 字段、差值及结论。未被官方接口或 testnet 证明的值不能用零、默认 false 或其他 Venue 的公式填补。

## Comments

- 2026-07-29：使用 44 个 OKX、Binance、Gate.io 和 Bitget 第一方直接链接完成研究并解决。
