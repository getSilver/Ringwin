# 01：协议依据、字段映射与样本

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何把用户提供的 Nautilus Hyperliquid 资料转成 Ringwin 可验证的协议合同，明确哪些行为可翻译、哪些需要共享合同补齐？

## What to build

遵循 [Adapter 手册](../../../docs/integrations/adapter-onboarding.md)，扩展现有字段处置矩阵，建立首期消息、来源及脱敏样本清单。主要参考 `D:/github/nautilus_trader/docs/integrations/hyperliquid.md`；只有缺失、矛盾或必须验证的关键事实补查官方资料，不继承 Nautilus 的回退策略或资格。

## 完成条件

- [x] 覆盖产品/规则、行情、订单、成交、余额、仓位、保证金、资金费、强平/ADL、配置观察及恢复消息；字段逐项分类并给出单位、事实身份与缺失/未知值处理。
- [x] 固定 Venue/环境/资金账户/签名钱包/Instrument/Asset 的绑定；BTC/ETH 与包装资产不按名称合并。首期仅标准永续逐仓及现货、同报价/结算资产配对。
- [x] 核实有效价格与数量规则、CLOID、签名序列化及测试向量、nonce 范围、REST/WS transport 选择、限流共享范围及重试条件；不硬编码参考项目的默认滑点或自动舍入。
- [x] 定义 RawIngress、流身份、捕获顺序、无源序号快照、分页终止/历史截断与完整性证据；未知覆盖不能宣称 ConfirmedAbsent。
- [x] 保存样本来源、查询日期、版本与内容身份；真实秘密及认证材料不进入样本。合成样本明确标记，不能证明在线协议。
- [x] 给出改动清单：调用方、测试、fixture、配置、入口、共享模型、持久格式与文档；将真实共享缺口交给 02/03，未证明能力明确 Unsupported 或 pending。

## Answer

2026-11-02：在 `feat/hyperliquid-adapter` 完成协议合同与样本；源码基线
`3265db098340ad4d6b7b3ff47baeaff108229341`，不提前实现 02–08。

- [协议合同与影响清单](../../../docs/research/2026-11-02-hyperliquid-protocol-contract.md)：逐项定义身份、单位、未知值、发送、恢复及共享缺口。
- [字段矩阵 §3.8](../../../docs/venue_field_disposition_matrix.md#38-hyperliquid首期协议合同)：产品/公共/私有/经济/配置/恢复字段处置，均标为目标映射而非已实现能力。
- [签名与历史依据](../../../docs/research/2026-11-02-hyperliquid-signing-history.md)：固定官方 SDK commit/version、无秘密公开 action-hash 向量、nonce/历史上限、完整状态枚举和 ADL 证据边界。
- [协议样本](../../../src/testing/fixtures/hyperliquid/README.md)：公开 Testnet meta/spotMeta/BTC/ETH l2Book 原始字节、15 组合成私有/错误输入、来源 UTC 与 SHA-256。没有私钥、认证头或可发送签名。

验证：

- 样本/来源检查通过：6 个文件 SHA-256 匹配，JSON 可读，15 个 case 身份唯一，REST/WS 重复与冲突向量关系成立，秘密字段扫描无命中，相关相对文件链接有效。
- `git diff --check` 通过。Standards / Spec 独立双轴审查均 0 项发现；最终同步地图后再次检查。
- `zig build test` 已运行一次；2026-11-02 约 13:35–14:05（UTC+8）在本轮 30 分钟预算内未返回完成结果，主动停止该测试及等待中的构建进程。未取得通过结论，也没有取得可归因本次变更的失败断言；不把本次尝试当作完整回归证据。
  终止后外层命令退出 1、构建进程退出 255；这是预算终止结果，不是某条测试断言的失败证据。
- 本票无运行逻辑变化，不引入 decoder/TDD seam 或持久格式版本；未运行 ReleaseSafe、签名或 Adapter 在线私有协议验收。

交接：02 负责真实 USDC 逐仓、捕获顺序/连续性、有效价格及费率精度的通用表达；03 负责私钥类型/秘密生命周期、签名验证和 nonce/fencing。
资金费/强制执行稳定身份与历史完整性由 05/06 继续证明；包装 BTC/ETH 的经济身份批准、流动性与 Testnet 交易资格保持 pending。
这些未证明能力不能用合成 fixture、元数据 listing 或现有 Venue 回归来关闭；01 resolved 只表示合同及交接完成。
