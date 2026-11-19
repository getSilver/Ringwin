# Hyperliquid Adapter 功能验收记录

关联 [08](../.scratch/hyperliquid-adapter/issues/08-testnet-qualification.md)。
2026-11-04 用户明确将验收范围限定为 Hyperliquid Adapter 功能；原票中的跨所策略、
真实节点装配、对手账户、部署配置和交易预算不再是本票完成条件。
本次结论是支持范围内的 Adapter 离线功能验收通过；真实网络交易与生产资格未取得。

## 当前执行身份

- 日期：2026-11-04；分支 `feat/hyperliquid-adapter`。
- 源码 revision：`ddc4eaad2cde73fbed99467439c735a756ed374c`；采集开始时 `git status --short` 为空。
- 平台：Windows 10 build 17763，Zig 固定版本 `0.17.0-dev.315+5b647b792`。
- 本次未修改源码、配置或 fixture；只新增本文并更新运行说明及本地 tracker，按用户澄清修正验收范围。
- 源码/fixture 身份清单：[source.json](../.scratch/build/hyperliquid08/source.json)，覆盖 Git 跟踪的
  `src/`、`python/`、`tools/` 及存在的构建文件，共 286 项；按路径排序的 `path`/`sha256`
  数组以 Python `json.dumps(sort_keys=True,separators=(',',':'))` 编码后 SHA-256 为
  `75fb9f7622fa0230cf2c41b4742d859d0d3394f5f5990af62b3ec539115a169a`。
- 公开观察原文与请求/响应 SHA-256 清单：
  [public-observation.json](../.scratch/build/hyperliquid08/public-observation.json)。
  这是被忽略的本地证据，归档前须连同原文、命令日志一起导出，不能只保留此链接。
- 在线写入、真实凭证加载、账户只读查询、主网访问：均未执行。

## 公开只读观察

2026-11-04 11:36:08–11:36:10（UTC+8），使用 Python 标准库 `urllib.request`，
向 `https://api.hyperliquid-testnet.xyz/info` 逐次 POST 以下 JSON，Content-Type 为
`application/json`，每次 timeout 20 秒，无认证头、无重试。五次响应均 HTTP 200。
原始采集源码保存为 [public-collector.py](../.scratch/build/hyperliquid08/public-collector.py)，
当次命令为 PowerShell 单引号 here-string 包含该源码并管道至 `python -`，工作目录为仓库根。
该文件是从执行命令保存的原样源码，不是另一次文件执行结果；不要在原证据目录重跑而覆盖旧响应。

| 请求体 | 原文 SHA-256 |
| --- | --- |
| `{"type":"meta"}` | `7427e4738f1722b6217d9ed0e11f7eac3a009aa68d2d41bd08ac6e4df6b58efd` |
| `{"type":"spotMeta"}` | `4fdfaaf05e465a23408276aa53896697f4071314c370822144a27e71e2216b6e` |
| `{"type":"l2Book","coin":"BTC"}` | `95c230e54f4af3e69779cf1d4f23f2fca50b4ce19ddc9987f09948fce1e5a913` |
| `{"type":"l2Book","coin":"ETH"}` | `a93947c23a1d61a59937c4968808a4d3c00fa52ccb92fdc1ee8eecca463d688d` |
| `{"type":"l2Book","coin":"@1137"}` | `448f5c41873e410df4ad96c74cf72c4639062a889f8eaf9f3f07d5781e73f961` |

| 产品 | 当次观察 | 尚缺依据 |
| --- | --- | --- |
| BTC 标准永续 | universe[3]，szDecimals=5，marginTableId=54；book 20/20 档，最优买/卖 76488 / 76497 | 实际部署的账户配置与流动性另行验证，不阻塞 Adapter 功能验收 |
| ETH 标准永续 | universe[4]，szDecimals=4，marginTableId=53；book 20/20 档，最优买/卖 2251.6 / 2251.7 | 同上 |
| 结算 USDC | collateralToken=0；token0，tokenId `0xeb62eee3685fc4c43992febcd9e75443` | 真实部署的 Asset 配置另行确认；Adapter 的绑定校验已由 fixture 验证 |
| BTC 现货候选 | token69，tokenId `0x286820da26c94f1e0ff1e436238f2384`，非 canonical，pair @50；无 UBTC 名称匹配 | 无获批 BTC 经济身份；未查询该候选盘口，不把同名 token 当 BTC |
| ETH 现货候选 | UETH token1242，tokenId `0xe4371d8166f362d6578725f11e0a14f3`，pair @1137，tokens [1242,0]；book 16/20 档，最优买/卖 80.04 / 120.0 | 包装资产批准、同原子单位 1:1 配对及可用流动性；不以名称或该盘口自动批准 |

这些值只描述当次响应，不进入批准配置，也不证明未来可成交。
完整 book 是 REST 观察，没有经 Ringwin MarketFeedAdapter/Owner 持久应用，不能作为正式行情资格。
现货 pair 索引和 token 索引分别核对；查询必须使用资金账户，不能用 agent 地址替代。
协议依据：[官方 Info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint)。

## Adapter 功能验收矩阵

验证边界为 VenueAdapter / MarketFeedAdapter、签名入口和经 Owner 的公开应用与恢复接缝。
测试输入为固定官方公开样本与明确的合成私有事实；真实 token 批准和市场流动性属于部署输入，
只验证 Adapter 对已传入绑定的严格校验，不将批准职责移入 Adapter。

| 功能 | 本次结论 | 验证内容 |
| --- | --- | --- |
| 签名与身份 | 通过 | 固定 SDK action hash、钱包/资金账户/环境/session 绑定；受保护测试凭证经正式签名路径及 nonce/fencing 回归 |
| 产品与规则 | 通过 | 现货/标准线性永续、真实 token/USDC 绑定、精确价格/数量及规则变化拒绝 |
| 公共行情 | 通过 | 有限深度、公共成交、标记/指数价、资金费率、重复/冲突、陈旧 session、断连与背压 |
| 订单编码 | 通过 | GTC/IOC/ALO、永续 Reduce-only、CLOID、撤单/查询；不支持的订单种类拒绝 |
| 私有事实 | 通过 | 明确拒单、部分成交、撤单终态、独立 Fill、费用/返佣、账户配置/余额；report/Fill 两种顺序 |
| 发送与安全 | 通过 | 明确未发送/不确定发送、过期/撤权/旧 session、限流与撤单预留；Unknown 保留原身份且不盲目重发 |
| 对账与恢复 | 通过 | 固定窗口/分页/截断/超时、重复事实、RawIngress 回放、snapshot 加尾部收敛；恢复零发送、不重授权限 |
| 真实网络下单/成交 | 未执行 | 不属于本次离线功能结论，不能由 fixture 或公开 REST 查询推导 |

现货 Reduce-only、现货资金费和现货逐仓配置不适用；标准永续对应合同已有离线验证。
BTC/ETH 指定现货的实际市场与包装资产批准仍未取得，不把同名 token 当作已批准资产，
也不因此否定 Adapter 对明确 token 绑定的功能验证。

## 本次验证

复用已有入口和测试，不新增 runner、配置审批、策略或节点功能。

| 命令 | 证据范围 | 本次结果 |
| --- | --- | --- |
| `zig build run -Doptimize=ReleaseSafe -- --hyperliquid-offline` | 既有 runtime/Host 与模拟对手的兼容性补充 | 退出 0，`hyperliquid_runtime_offline=passed`；[日志](../.scratch/build/hyperliquid08-main.log) |
| `python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -O ReleaseSafe --test-filter Hyperliquid --stack 67108864` | Adapter、公共行情、Gateway→Owner、权限与恢复 | 退出 0，35/35；[日志](../.scratch/build/hyperliquid08-directed.log) |
| `python tools/zig-entry.py test src/adapters/hyperliquid/hyperliquid_signer.zig -O ReleaseSafe --stack 67108864` | 额外签名定向尝试 | 编译阶段主动停止，未取得此命令的测试结果；SDK 向量与身份绑定已由下行完整套件覆盖，不重复编译 |
| `zig build test -Doptimize=ReleaseSafe` | 完整离线回归 | 退出 0；[日志](../.scratch/build/hyperliquid08-full.log) |

完整构建回归使用 `--listen`，日志保留诊断 stderr 与实际命令；结果以本次进程退出 0 为依据，
不把历史票据的测试数量当作本次直接运行计数。没有因文档变更重复运行已通过的完整套件。
本次不修改运行逻辑，复用已有行为测试；不增加与文档文字同构的测试。
签名覆盖依据是 `src/main.zig` 的 test 块实际导入 `hyperliquid_signer.zig`，其中包含
`L1 signing matches pinned SDK public action hash` 与
`signer sessions bind credential funding environment and owner without agent query fallback`；
不把上行主动停止的编译当作通过证据。

## 验收边界

真实 transport/节点装配、控制面批准配置、对手 Venue/账户、双 IOC/Maker–Taker 策略、
交易预算及真实交易授权属于后续项目/策略/部署验收，不再作为 08 或 Adapter 模块的关闭条件。
Adapter 本身的身份/环境/权限、限流、签名与错误分类校验继续保留，不为验收移除。
未使用真实私钥、访问资金账户或发送交易；本结论不表示 Testnet 真实成交或生产可用。

## 复审

验收基线为上面的源码 revision；按用户澄清后的 Adapter 范围复审文档及证据。
原始采集源码、调用方式与源码哈希见
[public-invocation.json](../.scratch/build/hyperliquid08/public-invocation.json)，
五份响应的字节数/HTTP 状态/哈希复核通过。Standards / Spec 按修正范围复审均无阻塞项；
不把旧范围的项目/策略条件重新加回 Adapter 完成条件。
