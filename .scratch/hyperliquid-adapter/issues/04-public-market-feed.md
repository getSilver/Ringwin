# 04：公共行情 Adapter

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 共享领域合同](02-shared-domain-contracts.md)、[04a 公共 MarketTrade 共享合同](04a-market-trade-contract.md)
Parent: [模块地图](../map.md)

## Question

如何让 Hyperliquid 公共市场事实经 MarketFeedAdapter 进入已有投影和策略输入，并准确保留有限覆盖与健康状态？

## What to build

在 `src/adapters/hyperliquid/` 实现独立公共行情生命周期，输出规范产品/规则观察、有限深度快照、市场成交、标记/指数价格、资金费率及健康事实。遵循 [深度合同](../../../docs/depth-snapshot-contract.md)，不绑定私有账户或凭证生命周期。

## 完成条件

- [x] RawIngress 先捕获再解码；产品观察不自行激活规则或授予交易权限。
- [x] 按当前每侧 8 档合同保留可见范围和截断，验证被截断尾部，不外推流动性、不伪造源序号；标记与指数价格不得互相替代。
- [x] 非法帧、过期、断连、规则变化和重订阅使对应资格失效；新快照必须满足 session、时点与恢复合同，旧排队帧不能错误恢复健康。
- [x] 订阅、队列、帧、重试与每轮工作有界，停机和背压不丢失必须提交的事实；不阻塞其他行情源。
- [x] 通过 MarketFeedAdapter 公共接缝到核心投影及 Host 输入验证正常/非法/缺侧/重复/迟到/溢出/重连，重放结果一致。
- [x] 注册适用共享契约及正式离线入口，记录 Debug/ReleaseSafe 结果；行情资格不宣称 maker 排队位置或成交概率资格。

## Answer

2026-11-03：实现、双轴复审和最终完整离线回归完成；04 resolved，未取得在线资格。

实现范围、正式入口、数值/时钟/容量限制及恢复责任见
[公共行情实现记录](../../../docs/research/2026-11-02-hyperliquid-public-market.md)。

- 起始基线 `77e57cc82ea17fcdcc4294594b3274b1187433d2`，分支 `feat/hyperliquid-adapter`，工作区起始干净。
- 本票识别并独立登记 04a 共享前置；补齐 MarketTrade，而非借用经济 Fill。
- canonical 20 / codec 15 / journal 52 / state 56 / registry 50；旧格式拒绝，无自动迁移。
- 公共行情、共享事件/codec/核心校验/Host、native manifest、正式测试入口与 core-wave 编排同步；无运行账户路由/真实 transport 接线（07）。
- Standards / Spec 两轴发现的时间屏障倒退已修正并补公开回归；重复 glossary 定义合并。两轴最终复审均无剩余阻塞。

### 当次离线证据

- Windows、Zig `0.17.0-dev.315+5b647b792`。`python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_market_acceptance.zig --test-filter Hyperliquid --stack 536870912`：Debug 13/13；追加 `-O ReleaseSafe`：13/13。日志为忽略的 `.scratch/build/hyperliquid-04-current-target-{debug,release}.log`。
- `python -m unittest discover -s python -p test_strategy_host_bridge.py`：8/8；`python -m py_compile python/strategy_host.py` 通过；`python tools/test-native-strategy-build.py`：8/8（日志 `hyperliquid-04-native-build.log`）。
- 定向覆盖官方公开 BTC book、BTC/spot metadata、8 档与尾部校验、缺侧/非法/冲突/重复/溢出、捕获失败、隔离、排队超时、规则变化、旧 epoch/旧断连、同 epoch 等待初始缓存书后的新书、批准摘要及重启规则变化、RawIngress 回放、核心稳定应用、明确数量单位、Host batch 与规范/快照加尾恢复。
- 复核修复：生命周期屏障只增不退；初始缓存书不升级健康也不推进订阅屏障；规则摘要必须由配置批准，覆盖引用 margin table，并跨新实例保持校验。后两项及最终夹具同步均经双轴复审。
- 格式升级后的五条固定轨迹先通过经济与稳定重放断言，再打印新摘要并在旧常量比较处失败；四分片先通过经济及三路径恢复一致性，再在旧摘要处失败。仅同步版本注释与摘要常量，保留全部断言。native 构建拒绝夹具的 schema 替换同步为 `20 → 21`，避免无效替换。
- 最终完整 ReleaseSafe：`zig test src/main.zig -O ReleaseSafe --stack 536870912 --test-no-exec -femit-bin=.scratch/build/hyperliquid-04-current-release.exe` 编译成功后，直接执行生成的测试二进制，**848/848 通过，退出 0**。日志 `.scratch/build/hyperliquid-04-current-full-{compile,release}.log`；包含既有 Venue、签名、安全、所有恢复/容量矩阵及本票公共接缝。未将定向 Debug 结果声称为完整 Debug 套件。
- 较早的构建监听/中间源码完整运行在最终源码冻结前停止，没有全量结论；最终完整结论只来自上述当前源码的独立运行。`zig fmt`、PowerShell 脚本语法及 `git diff --check` 通过。

未启动 05/07/08，未读真实凭证或执行在线订阅/下单。真实 transport、共享 IP 限流、RawSink 物理持久性、部署 epoch 高水位与规则摘要审批归后续接线/资格；不宣称 maker 排队、成交概率、Testnet 或生产资格。
