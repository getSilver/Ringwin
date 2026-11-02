# 01：协议依据、字段映射与样本

Type: task
Status: open
Assignee:
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何把用户提供的 Nautilus Hyperliquid 资料转成 Ringwin 可验证的协议合同，明确哪些行为可翻译、哪些需要共享合同补齐？

## What to build

遵循 [Adapter 手册](../../../docs/adapter-onboarding.md)，扩展现有字段处置矩阵，建立首期消息、来源及脱敏样本清单。主要参考 `D:/github/nautilus_trader/docs/integrations/hyperliquid.md`；只有缺失、矛盾或必须验证的关键事实补查官方资料，不继承 Nautilus 的回退策略或资格。

## 完成条件

- [ ] 覆盖产品/规则、行情、订单、成交、余额、仓位、保证金、资金费、强平/ADL、配置观察及恢复消息；字段逐项分类并给出单位、事实身份与缺失/未知值处理。
- [ ] 固定 Venue/环境/资金账户/签名钱包/Instrument/Asset 的绑定；BTC/ETH 与包装资产不按名称合并。首期仅标准永续逐仓及现货、同报价/结算资产配对。
- [ ] 核实有效价格与数量规则、CLOID、签名序列化及测试向量、nonce 范围、REST/WS transport 选择、限流共享范围及重试条件；不硬编码参考项目的默认滑点或自动舍入。
- [ ] 定义 RawIngress、流身份、捕获顺序、无源序号快照、分页终止/历史截断与完整性证据；未知覆盖不能宣称 ConfirmedAbsent。
- [ ] 保存样本来源、查询日期、版本与内容身份；真实秘密及认证材料不进入样本。合成样本明确标记，不能证明在线协议。
- [ ] 给出改动清单：调用方、测试、fixture、配置、入口、共享模型、持久格式与文档；将真实共享缺口交给 02/03，未证明能力明确 Unsupported 或 pending。

## Answer

尚未开始。地图中的只读元数据观察仅作线索，不关闭本票。
