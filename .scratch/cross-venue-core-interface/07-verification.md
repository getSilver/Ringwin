# 07 原生 Post-only 验证

2026-10-22。实现基线 `5f8286573e7f84dce73f1f526914cd9ca1b4c1ca`；固定 Zig `0.17.0-dev.315+5b647b792`，Windows 本机离线。

用户于2026-10-22明确选择按现有版本、规则、会话失效及命令时限验收07，并保留“能力声明不会因长期未更新而自行到期”的限制。不增加独立能力 TTL；该选择不是定时刷新或自动重新验证能力的承诺。

## 实现合同

Host 的 OrderIntent V1 增加 order_type=2（post_only）、time_in_force=3（post_only）；原 limit=1、GTC=1、IOC=2 保持。单意图 schema 1、完整组 schema 2、80-byte 成员、448-byte 组上限及原会话/激活/新鲜度检查不变。Zig OutputOrder 显式携带 order_type；Python `--time-in-force=post-only` 同时输出上述两个值。未知枚举继续拒绝；旧读者遇到新增枚举失败关闭。持久字段布局和长度不变，journal/state/registry 保持43/47/41，不新增自动迁移或双读。

核心的单意图和完整组转换均保留原生要求，复用既有 canonical Post-only 和 OMS exactOrderSpec。Post-only/GTC、limit/Post-only 错配不能产生命令。单意图、组身份及捕获的原始 Host 帧绑定该要求，重复或恢复不能把它改成 GTC。核心仍拥有共同准入、预留和周期占用，Python 不获得发送权限。

准入要求当前账户品种的版本化能力支持原生 Post-only；无能力、规则升级使能力失效或能力明确不支持时拒绝。能力激活复核账户、Venue、产品、规则和配置，拒绝旧版本。发送时 Gateway 复核当前权威引用、路由账户、Venue、环境、产品、能力版本、会话与 dispatch deadline；适配器再检查自身能力并映射原生协议，不能降级或自行模拟。现有能力合同没有单独的证书 TTL；新鲜度由当前版本/会话/规则引用及基于 max_dispatch_age_ns 固定的命令期限共同限制，本票没有创造新的线上资格来源。

准入前失败不提交半组、命令、资金预留或周期；准入后能力变化只阻止发送，不回滚已提交命令、预留或周期。即使新能力仍支持 Post-only，旧命令不能借新版本再次取得权限。已接受发送重复查询可返回原 accepted 结果但不调用适配器；Unknown 保持原命令与可能量，不能自动重发、重建 GTC 或延长期限。周期释放仍归09a。

已发送 maker 在原生能力撤销后仍允许显式撤单。OMS 保留原订单的 Post-only 语义，Gateway 与 Binance/Bybit 只对 place/amend 检查原生创建能力；cancel 继续检查当前账户、会话、版本、权限及期限。撤单不重写订单为 GTC，也不提前释放预留。公共回归先观察真实 canonical accepted 报告，再撤销能力并提交撤单；适配器契约同时覆盖能力缺失时 place 拒绝、cancel 可编码发送。

## 证据分层

- 传输：真实 Python 子进程经匿名 pipe → Host Gateway → Owner；同时保留原 GTC 和新增 Post-only 的文件关闭重开验收。
- 核心：单意图及 maker–taker 完整组、全组拒绝、规则升级后能力缺失、错误能力激活、准入后版本变化、journal tail 和 checkpoint 恢复。
- Gateway：两账户命令送达离线 VenueAdapter；原生 maker 发送意图/发送结果的 append/commit 故障，Unknown 原证明恢复、不重发及提交状态保持。共同准入的全部故障切点沿用05的公共持久事务证据；双腿通用发送故障沿用06，本票补原生语义保真。
- 适配器：离线真实实现 `VenueAdapter.trySend → 编码 → 可控 transport → tryDrain`，OKX ordType=post_only、Binance spot LIMIT_MAKER / linear GTX、Bybit PostOnly。能力不支持在 transport 前拒绝；这些是软件契约证据。
- 实际 Venue：本轮未运行网络、Demo/Testnet/真实下单，任何 Venue/账户/产品/环境运行资格均未由本票取得。既有 verified_native_post_only 等资格标记不升级。

## 实际验证

| 命令 | 结果与边界 |
| --- | --- |
| `zig test src/main.zig -O ReleaseSafe --stack 536870912` | 最终699/699，退出0；`.scratch/build/07-final-full-suite.log/.exit`；进程已退出 |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/native_post_only_acceptance.zig --test-filter "unsupported native maker" --test-filter "capability activation rejects" -O ReleaseSafe --stack 536870912` | 修正后的两项验收及入口测试3/3，退出0；`.scratch/build/07-corrected-cases.log/.exit` |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" run src/testing/integration/strategy_host_integration.zig -O ReleaseSafe --stack 536870912` | 退出0；真实 Python Host 的 GTC/Post-only 两种多账户文件恢复与既有单/组路径通过；`.scratch/build/07-host.log/.exit` |
| `python python/test_strategy_host_bridge.py` | 5/5，退出0 |
| `python python/test_strategy_checkpoint.py` | 7/7，退出0 |
| scoped `zig fmt --check`、`git diff --check` | 均退出0；`.scratch/build/07-format.log/.exit`、`07-diff-check.log/.exit` |

新增 Host 原生枚举测试先以 Malformed 失败，再补齐入口；能力撤销后撤单回归先以 NotSent 复现问题（`07-cancel-red.log/.exit`），再收窄共享 Gateway 和 Binance/Bybit 的原生创建能力检查。首次全量697/699（`07-first-full-suite.log/.exit`）的两项失败均为新增fixture前置条件：规则升级后的行情失效掩盖能力缺失检查、错误Venue先由外层scope拒绝。已用新规则恢复公开行情再精确断言能力拒绝，并按外层CanonicalScopeMismatch修正账户/Venue/环境预期；定向3/3通过后复跑最终完整回归。

Standards 和 Spec 双轴复审均无遗留发现。Spec 初审发现撤销原生能力也阻止安全撤单，已修复并复审；用户确认现有失效语义后，独立 TTL 的验收歧义已消除。复审结论是源码证据，运行结果单列。

## 保留边界

没有部署、下单、凭证访问或 GitHub 同步。没有队列位置、成交率、对冲收益或完整 Maker–Taker 资格结论。真实模型/checkpoint 与周期激活归08/09，综合策略归10。多账户产品发布入口及 deployment/production qualification 保持关闭；大栈离线验收不证明部署资源资格。
