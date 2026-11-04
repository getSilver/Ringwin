# 07：运行组装与跨所接线

Type: task
Status: resolved
Assignee: Codex
Blocked by: [04 公共行情](04-public-market-feed.md), [06 对账与恢复](06-reconciliation-recovery.md)
Parent: [模块地图](../map.md)

## Question

如何通过已有运行入口和控制面使用 Hyperliquid，并让现有两腿策略消费其规范能力？

## What to build

在现有 runtime、配置登记与构建入口组装 Adapter，复用 Web 控制面、Owner、账户路由及 StrategyHost。核对现有跨所策略的 USDT 限定，只补齐同结算资产 USDC—USDC 支持，不重写策略。

## 完成条件

- [x] 登记 Venue/环境/账户/品种、资产规则和真实 capability；缺失能力拒绝，能力刷新不恢复已撤销的交易授权。
- [x] 两腿只允许相同报价/结算资产，现货包装资产保留身份且有明确批准的经济配对；不加入稳定币兑换或跨资产抵押。
- [x] 既有共同准入、预留、双 IOC、Maker–Taker 撤旧后新建及周期恢复贯通；内部原子性不冒充外部成交原子性。
- [x] 默认入口离线且不加载真实凭证；只读、Testnet 写入和生产权限隔离，不能套用其他 Venue 的 Demo 开关。
- [x] 账户配置读写接口按已有控制授权边界接入；若确需新增写入合同，先列明通用请求和调用方影响，禁止任意 Venue API 透传及 Adapter 自主改杠杆。
- [x] 复用 src/entry.zig、tools/zig-entry.py 和既有离线编排；更新配置说明、能力/字段矩阵和必要调用脚本，不建立第二套 runner/CLI。
- [x] 经实际运行组装验证隔离、旧 session、权限失效、单腿失败及 Unknown；既有 Venue 回归通过，离线双腿证明与在线资格分开。

## Answer

2026-11-04 完成离线实施、最终回归及两轴复审。运行配置及权限边界见
[运行接线](../../../docs/hyperliquid-runtime.md)。

### 实现范围

- `src/runtime/hyperliquid_runtime.zig` 从对应账户的 Owner 已提交视图装配 Adapter、Gateway 路由和独立公共 Feed；批准配置摘要、私有/公共索引与单位精确一致。capability 激活与交易授权仍分离。
- 环境增加明确 Testnet 接缝值，沿用 simulation/Demo 原有编号；配置不接受 Demo 或 production。只读资源没有钱包；Testnet 写入另需明确授权、期限及钱包/账户/session/lease 绑定，实际提交前复核。未读取真实凭证。
- 订阅 epoch 先持久消费，恢复完成中断的 seal/snapshot/rotate，允许跳号而不回退；公共原文附捕获配置/完整元数据/decoder 序列，回放核验后只经 Owner 应用，不能重发或重新授权。
- 现有主入口与 core-wave 增加 Hyperliquid 离线编排；现有 authority probe 增加明确的离线模式，复用原 Web/package/Host 协议。没有第二套控制面。两腿对手为 SimulatedVenue，不能称为真实跨所交易。
- 现有 Python 双 IOC、Maker–Taker 算法按真实报价/结算 Asset 配对；支持 USDC—USDC，混合 USDT—USDC 仍拒绝。包装现货可显式批准同原子单位 1:1 经济配对，真实资产及费用身份保留；批准变更使配置/checkpoint/评估身份失效，原有无批准配置摘要不变。
- 运行测试发现 Host 的规范 `limit + IOC` 被 Adapter 拒绝，已在公共命令校验根因处支持；FOK、market、原生 amend 和不匹配 TIF 仍拒绝。
- 共享 AdapterRequest 没有账户配置写入命令，沿用只读配置事实与准入检查，不增加任意 API 透传或 Adapter 自主改杠杆。将来若需自动写入，先单列通用合同及调用方影响。

### 验收边界

本票交付离线 runtime/control/Host 接线与可注入 Testnet 资源边界；真实 transport、共享 egress 拓扑、实际在线节点资源和指定市场须在 08 显式授权后验证。Linux production dispatcher 仍只有既有模拟生命周期，Windows Demo 流程仍是 OKX 专属，不以本票离线节点替代它们。

BTC/ETH 包装现货实际身份、真实对手 Venue 的同结算资产市场、资金/流动性、历史保留与共同账户屏障仍 pending；没有 Testnet 写入或生产资格。

### 复审与证据身份

- 实施基线：`70a63b8b371173fbbf8eceda1fd6f5cf6ed3d203`，分支 `feat/hyperliquid-adapter`。最终源码树 SHA-256：`c798d4b5ccce38beb36d2594f72b22fcd101a1c5fcfd548a14148acdf3624ebd`，覆盖 `src/`、`python/`、`tools/` 与构建文件共 286 个文件，不含文档和票据；清单身份见 [source.json](../../build/hyperliquid07-source.json)。
- Standards / Spec 两轴审查并在修复后复审，当前源码无剩余阻塞项；审查未替代实际运行或在线资格。
- 首轮最终回归曾出现公共原文旧前缀被再次应用导致的 `StaleCanonicalIdentity`（完整 ReleaseSafe 为 869/870），实际主入口也曾遇到栈溢出。这些失败不能作为通过证据。修复为严格跳过早于 Owner 已提交游标的事实、保留同游标冲突验证、初始化先恢复已捕获而未应用的公共原文，再接续序列并消费新 generation；离线场景使用自有 512 MiB worker 栈。恢复边界定向 2/2 通过，见 [定向日志](../../build/hyperliquid07-replay-complete.log)。
- `multi_account_authority_acceptance.zig` 随修改按 `zig fmt` 统一了原 CRLF；其语义变更为沿用既有 Owner 夹具支持真实结算 Asset 与现货首腿，并未重写测试主体。
- 最终 `zig build test -Doptimize=ReleaseSafe` 退出 0，但显示 `run test w` 与 `failed command`，与 03 的历史现象一致。本机固定 Zig 的 `lib/compiler/build_runner.zig:1379` 对非空 stderr 无论成功与否均调用诊断打印，`:1514` 将 `Run.zig:1541` 保存的命令统一标为 `failed command`；不能仅凭该标签断言测试或 Ringwin 日志持久化失败。完整结果以同一生成二进制无 `--listen` 的直接运行汇总为准。

### 最终验证

| 命令 / 场景 | 结果与证据 |
| --- | --- |
| `python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -O Debug --test-filter Hyperliquid --stack 67108864` | [35/35](../../build/hyperliquid07-debug-accepted.log) |
| 同一定向命令，`-O ReleaseSafe` | [35/35](../../build/hyperliquid07-release-accepted.log) |
| `zig build test -Doptimize=ReleaseSafe` 生成的完整 ReleaseSafe 二进制直接运行（不带 `--listen`） | [870/870，退出 0](../../build/hyperliquid07-full-direct.log)；二进制为 `.zig-cache/o/2409c06cdb10a782507b4d7f131ae654/test.exe`，覆盖最终源码 |
| `zig build run -Doptimize=ReleaseSafe -- --hyperliquid-offline` | [hyperliquid_runtime_offline=passed](../../build/hyperliquid07-main-accepted.log)；实际主入口运行 24 种结算资产、产品组合、IOC/Maker 与发送结果场景 |
| `zig build strategy-authority-probe -Doptimize=ReleaseSafe` | [构建退出 0](../../build/hyperliquid07-probe-accepted.log) |
| 原 `test_strategy_instance.WebInstanceTests` 的 Hyperliquid 接线、既有完整组、单腿启用及暂停撤权三项 | [3/3](../../build/hyperliquid07-web-accepted.log)，无 skip |
| `python -m unittest discover -s python -p 'test_arbitrage*.py'` | [225/225](../../build/hyperliquid07-python-final.log) |
| `python -m unittest discover -s python -p test_hyperliquid_pairing.py` | 4/4，USDC 双 IOC、显式包装配对、USDC Maker 撤旧新建、批准身份变化 |
| 修改 Zig 文件 `zig fmt --check`、`git diff --check` 与 core-wave PowerShell AST 解析 | 全部通过 |

完整 ReleaseSafe 二进制 SHA-256：`85ab88acd93abc06d21579377d4de63fd84f8ca2c667dc8178c23b024edbd880`。

未运行完整平台 `verify-core-wave.ps1`，没有访问 Demo/Testnet 凭证、网络交易或生产资源；以上只证明离线接线。
