# 费用调整的 Venue 凭证边界

核对日期：2026-10-22。本记录区分外部接口事实与 RingWin 首版 canonical 合同，不能据此宣布真实 Venue 费用更正已经取得资格。

- [IBKR CommissionAndFeesReport](https://www.interactivebrokers.com/docs/tws-api/ref/commission-and-fees-report) 使用 `execId` 关联执行，并提供费用及币种。这支持成交与费用分开报告的设计；该对象本身没有提供 RingWin 要求的独立更正身份、前版本和修订链合同。
- [IBKR Execution object](https://www.interactivebrokers.com/docs/tws-api/doc/order-management/execution-details/the-execution-object) 描述 `.01`、`.02` 后缀对应执行更正。执行更正可能涉及成交语义，不能直接当成只改变费用的更正凭证。
- [OKX 账户账单](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-3-months) 提供账户余额变化记录及账单/订单/成交关联字段，可用于对账。已检查资料不足以确认通用的只改费用修订协议，不能将同一 Fill 的费用字段变化或余额差自动翻译成 FeeAdjustment。

RingWin 的独立调整合同要求适配器提供原 Fill 引用、可信原归属、独立来源身份与证据、明确前版本、新非负费用及有效时间。公共夹具可以验证核心接受该合同后的账务、幂等和恢复行为；夹具不证明现有 OKX 实现已能从真实私有事件生成这些证据。未支持该合同的适配器继续失败关闭。TradingRebate 独立，首版费用调整不修改返佣。
