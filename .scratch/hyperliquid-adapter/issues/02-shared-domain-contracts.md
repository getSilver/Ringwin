# 02：USDC 逐仓与必要共享合同

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 协议与字段合同](01-protocol-field-contract.md)
Parent: [模块地图](../map.md)

## Question

如何让共享合同准确表达 USDC 线性逐仓和无源序号的有限深度快照，同时保持既有 Venue、经济事实及恢复语义？

## What to build

按 [ADR 0022](../../../docs/adr/0022-separate-margin-model-from-settlement-asset.md) 分离模型与结算资产；仅实现 01 和当前源码证明的共享缺口。复用既有资产、品种、行情和风险合同，不添加 Hyperliquid 专用核心分支。

## 完成条件

- [x] USDT/USDC 使用真实独立 Asset，分别绑定规则、保证金、费用及损益；不得合并余额、固定汇率或跨资产抵押。全仓等未支持模式显式拒绝。
- [x] 覆盖 Product、MarginModel、风险、经济投影与现有消费者；异资产不能混加，包装资产仅经批准建立经济配对。
- [x] 捕获顺序与 Venue 连续性证据可区分；有限快照声明覆盖/截断，不能用本地自增数冒充交易所连续序号。
- [x] 若有效价格规则不能由当前合同表达，补齐通用规则及验证；发送不悄悄修改已授权价格或数量。
- [x] 列全 codec、journal、snapshot、digest、registry、fixture 和恢复校验影响；持久语义变化按版本合同处理，不能复用不兼容旧格式身份。
- [x] 通过公共核心入口、编码与恢复测试验证正常、错资产、错规则、溢出、旧格式和快照失效；既有 Venue 与模拟实现明确支持或拒绝新语义。
- [x] 记录实际 Debug/ReleaseSafe 及适用既有回归结果；纯命名变更或孤立模块通过不算完成。

## Answer

共享合同、离线回归与双轴审查完成；本票 resolved，不代表 Hyperliquid Adapter 或在线交易资格。

### 实现与影响

- `Product.isolated_linear` / `isolated_linear_v1` 分离模型与币名；账户配置显式绑定结算 Asset，既有 instrument、后续配置与协调摘要拒绝异结算资产。USDC 独立资产定义、code binding、原生 atoms、风险、预留、费用及账本经公共入口验证。
- 每账户经济投影仍只支持一种结算资产，多账户沿既有分区隔离；未引入兑换、固定汇率、跨资产抵押或包装资产别名。同结算资产的具体跨所策略配对准入由 07 接线，通用 IntentGroup 不新增任意经济配对假设。
- 捕获型有限快照携带 `sequence_kind` 与单调 `capture_epoch`；计数不能冒充 Venue 连续链，capture 后 delta 拒绝。gap 后更大 epoch 允许计数重置，旧 epoch 拒绝。Zig/Python 深度桥保留证据；覆盖/截断与未知数量语义保持。
- 通用价格约束表达有效数字、小数位上限及整数例外，风险前与 Gateway 发送前使用相同校验，不舍入/改价。新增原生摘要携带结算 Asset 身份。
- canonical 19 / codec 14 / journal 51 / state 55 / registry 49，StateDigestV15，协调快照 19；原生 manifest 同步兼容身份。旧格式失败关闭，不提供自动迁移。
- 既有 OKX/Binance/Bybit/Simulated 产品消费者、fixture、配置、codec 和恢复引用同步。实际 Venue 能力仍由其已有品种/资产定义决定，本票不登记 Hyperliquid Adapter 或在线能力。

影响清单及约束详见 [ADR 0022](../../../docs/adr/0022-separate-margin-model-from-settlement-asset.md) 与[深度合同](../../../docs/depth-snapshot-contract.md)。

### 当次证据

- 基线 revision `6e4bd6d869d4e34058918dfffc7f2e24a215d939`，分支 `feat/hyperliquid-adapter`；工作区起始干净，交付提交身份由本票 Git 历史记录。
- Zig `0.17.0-dev.315+5b647b792`，Windows，完全离线。
- Debug：PriceConstraints 公共校验 2/2；`USDC isolated` 核心公开入口 2/2。后者覆盖真实 USDC 预留/费用、非法价格、异资产规则/资金费拒绝、capture 重连/旧 epoch、规范日志重放、快照加稳定尾、非法价格规则快照失效。
- `zig build test -Doptimize=ReleaseSafe` 完整运行：826/828 通过；两项失败是升级后的四分片摘要和生产 schema 冻结预期，已同步，schema 定向 2/2 通过，四分片入口定向 2/2 通过。未将初次失败日志写成完整全绿结果。
- 初次四分片入口（包含传递测试）362/365；三项旧预期分别为四分片摘要、schema 断言和编译时尚未更新的固定轨迹摘要。完整 suite 的固定轨迹已通过，四分片实际经济断言与三路径恢复一致后更新摘要并定向通过。
- `zig build -Doptimize=ReleaseSafe` 构建完成，退出 0。
- 首次 Python discover 338 项，64 fail / 4 error / 3 skipped；失败来自尚未构建的 candidate engine/native manifest。补齐后完整重跑 344 项：6 fail、3 skipped，其余通过；6 项全部因 native Web 安装夹具仍固定 registry 48 被当前 runtime 49 拒绝。
- 同步 registry 后定向复验 6 项：1 pass / 5 fail，进一步暴露夹具从公共 Debug 输出读取清单、节点却在临时目录按 ReleaseSafe 构建的错误。修复为 probe target 安装同构建清单、夹具读取本地清单并从实际定义取得 registry，移除手工追加注册定义；运行时严格校验不变。最终 `python -m unittest test_native_strategy_instance.NativeWebTests test_strategy_contract_e2e.NativeLifecycleTests`：6/6 通过，306.958 秒。最终修复后仅重跑失败测试类，未再次声称全量 discover 全绿。
- `python tools/test-native-strategy-build.py`：8/8 通过；USDC 核心公共回归 ReleaseSafe：2/2 通过。
- Standards/Spec 两轴审查：发现并修正恢复遗漏的价格规则范围校验、capture 实例计数重置边界；复审无新增 02 阻塞项。

本机详细输出位于忽略的 `.scratch/build/hyperliquid-02-*.log`。未读取凭证，未运行 Testnet/Demo/主网交易，不授予在线或生产资格。
