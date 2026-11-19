# 设置驱动扫描：两层业务缺口核验

日期：2026-11-16。源码基线：`22ca6eca`。票 [06](../../.scratch/settings-driven-scanner/issues/06-integrate-and-retire-static-config.md) 保持 open。本记录是前置事实核验和失败复现，不是修复或验收通过记录；本轮未修改运行源码。

## 实际入口复现

命令：`python .scratch/build/scanner-gap-verification/probe_runtime.py`。

此探针复用 `python/test_scanner_integration.py:IntegrationTests` 的登录、设置、范围和 HTTP 操作；只替换公共网络 transport 的协议字节，实际执行现有 Zig worker、解码、RawIngress、规范盘口及 `ScannerRuntime.step()`。没有向 publish 注入 Plan，也没有替换评估计算结果。Native 二进制是工作区现有构建，本轮没有重新构建或独立确认它与当前源码完全一致。

| 验收断言 | 实际结果 | 判定 |
| --- | --- | --- |
| SOL 动态双源进入跨所配对 | 两路规范盘口；各 3 次 capture、6 条 RawIngress 记录；候选 0 | FAIL |
| DOGE 动态双源进入跨所配对 | 两路规范盘口；各 3 次 capture、6 条 RawIngress 记录；候选 0 | FAIL |
| 正常运行供应非空 plans | ETH 发布 1 次，plans 数 0，真实 evaluate 调用数 0；3 个候选均 missing_evidence | FAIL |

最终 `Ran 3 tests in 5.043s; FAILED (failures=3)`。完整原始输出：`.scratch/build/scanner-gap-verification/runtime-result.txt`。这是红灯验收探针，不能计为通过的回归测试。它证明当前症状，不证明补齐材料后的正式入口行为。

源码对应：`scanner_runtime.py:34,426,437,456` 对 BTC／ETH 进行特殊共享；`:610` 恒传空计划；`:633` 恒定缺项列表。`arbitrage_scanner.py:265` 已调用完整 `arbitrage_evaluation.evaluate()`，无需另建价差算法。

## 官方来源与在线目录核验

命令：`python .scratch/build/scanner-gap-verification/probe_public_sources.py`。仅查询公开目录，无凭证。响应及摘要保存在同目录的 `hl-meta.json`、`hl-spotMeta.json`、`okx-swap.json`、`public-source-summary.json`。网络成功不等于实际 native 在线行情验收；本探针未请求在线盘口。

| 来源 | 当前响应 | 可以支持的事实 | 尚未提供的关联依据 |
| --- | --- | --- | --- |
| Hyperliquid `meta` | 235 行，包含已退市行；字段为 name、szDecimals、maxLeverage、marginTableId、onlyIsolated、marginMode、isDelisted 的并集 | 合约目录、尺寸精度、保证金配置 | 链／原生资产或代币身份、perp 到 spot token 的外键、可验证的别名和缩放关系 |
| Hyperliquid `spotMeta` | 517 个 token；包含 tokenId、evmContract、isCanonical、fullName | HyperCore 现货 token 身份及精度 | 不能仅按 name 将现货 token 关联为永续底层资产 |
| OKX `instruments?instType=SWAP` | code=0，544 行 | 自身合约的 uly、ctVal、ctMult、ctValCcy、settleCcy、lotSz、minSz 等 | 不提供 Hyperliquid 的资产外键 |

响应 SHA256：

- HL meta：`3fcc787862033a6d3ef452c3a35323eefe3588bed11577cab66b0f0ae949b8d8`。
- HL spotMeta：`9b3999bdc43a4f55cb582497c6f04b91e679aaf7d8429a97d40d4bb6d33e9c8d`。
- OKX swap：`507a3383a2cae03742f542497c0d6df2c3b9a4eb3d1f5c58e12180eb6ff72484`。

官方证据：

- [Perpetuals info](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals) 描述 meta、metaAndAssetCtxs、perpDexs；上下文价格和 funding 本身不是资产身份。
- [Spot info](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/spot) 描述 spotMeta／tokenDetails 的现货 token 合同。
- [Asset IDs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids) 定义 perp 的目录索引与 spot 的不同编号规则；此编号不能用作跨所经济资产身份。
- [Info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint) 明确 UI 的 BTC/USDC 可以实际指向 HyperCore UBTC/USDC，故 UI 同名也不能证明包装资产可互换。
- [官方 SDK types](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/master/hyperliquid/utils/types.py) 的 PerpMeta／SpotMeta 描述各自接口类型，没有补充两者的通用身份关联。
- [合约规格](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/contract-specifications) 描述标准加密永续的计价／结算和单位语义；该一般规格不能为任意名称单独证明底层身份或缩放关系。

当前结论限于上述实际核查来源：尚未获得可自动验证 SOL／DOGE（以及一般目录资产）跨所身份的完整关联方法。不能将这个结论扩大为所有官方来源均不存在；也不能据此新增可信品种文件、扩展 BTC／ETH 名单、按同名／前缀／大小写合并。第一层前置来源问题尚未解决。

## 评估输入供应的当前事实

按当前源码核对，不沿用旧票“工具完成”的结论：

| 现有模块 | 当前实际产物或能力 | 运行入口尚缺的部分 |
| --- | --- | --- |
| `arbitrage_baseline.fit_ar1` | 从已给定且分区的历史 Point 训练 AR1 | 运行数据采集／版本发布／加载／适用域和时钟合同 |
| `arbitrage_probability.calibrate` | 从已给定历史 blocks 计算 Calibration | 真实历史与独立性证据、分模式／阶段／数量的发布与加载；不得在启动时凭空生成合格校准 |
| `arbitrage_research.summarize/Study` | Report 与 journal；freeze 返回候选身份；Report.economic_qualified 默认为 False | 不输出 Scanner Plan 或可直接加载的 Estimator／Calibration／FeeRule 参数包 |
| `arbitrage_maker_research` | 从真实 Cycle/Facts 结构提取 Maker 联合诊断 | L2 不能补出 Maker 部分成交、排队与条件对冲的真实标签 |
| `arbitrage_economics` | quantity_grid、sweep、estimate_fee、funds_fit、资金费和完整周期成本函数 | 在实际运行组装中供应版本化费用、可用资金、风险约束和适用范围；按真实深度和单位生成合法数量 |
| `arbitrage_evaluation` | 完整参考／计划周期、条件延续、费用、资金费和失败处置 | 当前入口没有生成并供应任何 Plan；不得用恒定“缺材料”作为最终实现 |
| `scanner_archive`、`ScannerConsole.replay` | 数据型 freeze/load 与原始扫描输入重放 | 可复用编码和重放，但归档解码不等于可信研究产物准入，也不自动产生新盘口下的合法计划 |

材料缺失并不意味着不能开发供应、校验、失效和加载流程；它限制真实输入下的通过结论。本轮没有实现这些流程，不能以此核查代替第二层修复。

## 必须保留的经济单位边界

当前 scanner 的 Hyperliquid 行记录了 quote 和 settlement；`_entry()` 转成 Python `InstrumentRules` 时只带 base／quote。`arbitrage_evaluation._close_leg()` 计算线性价格差并在 `value_exit()` 汇总同一 quote 单位金额，没有独立的每腿结算资产损益与跨资产估值合同。费用资产估值只能解决费用，不足以证明整个永续损益已正确换算。

[Hyperliquid 官方合约规格](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/contract-specifications) 说明通常 USDT 计价、USDC 结算，协议内部并不按 USDC／USDT 汇率转换。对应本仓库 [ADR 0022](../adr/0022-separate-margin-model-from-settlement-asset.md)，不能把两个币固定按 1:1 合并。第二层实现需要在既有经济／评估合同中显式保留并校验此边界，再接 Plan；只填非空 plans 还不足以通过经济验收。

此外，当前扫描结果将评估器拒绝也编码为 pending；需要区分实际评估拒绝与数据不足，并同步现有页面消费者。没有完成页面或通过／拒绝全链路验收。

## 实施与验收仍待完成

顺序保持用户要求：资产关联 → 评估输入供应 → 动态计划与完整评估 → 页面和完整链路验收。全部在 06 内继续，不增加 GitHub issue。

1. 取得并验证动态身份来源，保存来源证据、单位、环境和关联内容版本；没有依据的具体品种报告接入缺口。撤销 BTC／ETH 特殊待遇不意味着去掉验证。
2. 研究产物发布／运行加载分别明确 schema、内容哈希、时间基准、适用数量／模式／maker 腿、有效期与缺项原因；费用、资金和风险独立版本化。保留真实输入缺失，不制造合格材料。
3. 合法数量和三种执行计划复用现有经济、预测、概率模块；处理计价与真实结算单位、步长、最小数量、合约乘数、深度、部分成交与失败。需要具体输入的状态必须来自实际准入结果。
4. 通过／拒绝／数据不足的公开结果和页面联动；输入、费用、规则或模型失效立即撤销旧机会。同一组原始输入与直接 evaluate、扫描、历史重算对齐。
5. 两个名单外品种实际 Python／Zig／页面验收，以及发现顺序／重启／换序、同名不同资产／包装／缩放／环境隔离、登记集合／部分写入恢复／新品种开关回归。内部确定性证据和在线证据分别记录。

本轮没有写业务源码、提交、推送、部署、读取凭证或下单。受限的研究子代理没有可用工具，未能核验或写报告；本记录全部来源核验和执行证据由主代理完成，不是独立审查通过。

## 现有回归复验

首次在 `python/` 工作目录运行 `python -m unittest test_scanner_integration test_arbitrage_scanner`：63 项，61 通过、1 失败、1 错误。错误为 `test_relative_run_directory_starts_the_normal_native_feed` 依赖仓库根目录 `.scratch/build`，从 python 子目录启动导致 FileNotFoundError；失败为 `test_periodic_refresh_ttl_and_other_consumer_ownership` 的 worker 集合断言。没有修改源码来修复或掩盖此结果。

随后在仓库根目录将 python 加入 sys.path，仅复验这两项：2/2 通过，3.868s。第二项先前失败的原因未单独确定，不能宣称整个 63 项首轮全绿，也没有把既有测试通过当作两层业务验收通过。新增需求探针仍为 3/3 失败。`git diff --check` 通过；未运行全量 Python／Zig 构建、UI 浏览器或在线盘口验收。
