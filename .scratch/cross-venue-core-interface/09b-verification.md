# 09b 策略周期恢复与核心激活验证

2026-10-29；worktree `D:\github\Ringwin-08-checkpoint`，分支 `codex/08-real-strategy-checkpoint`。实现依次为 `00438d84`、`1c4f169e`、`9d0272ea`；最终代码及下述全量结果对应 `9d0272ea`，本次收尾仅修改验证记录与本地 tracker。09b 按 Windows 本机离线公共接缝范围完成；09 汇总、10 综合验收及来源策略 spec 不随之关闭。

## 环境与命令

Windows 10 build 17763 AMD64，CPython 3.9.18（MSC 1916，64 bit），Zig `0.17.0-dev.315+5b647b792`，ReleaseSafe，栈 536870912 bytes。所有输入为明确的离线夹具，无 Venue 网络或凭证。

在上述 worktree 执行：

```powershell
python -m unittest discover -s python
zig test src/main.zig -O ReleaseSafe --stack 536870912
python python/verify_strategy_host.py
python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912
```

| 验证 | 实际结果 | 本地日志与独立退出码 |
|---|---|---|
| Python 全量 | 243/243，197.660 秒，exit 0 | `.scratch/build/09b-python-full.log`、`.exit` |
| Zig 全量 | 819/819，exit 0 | `.scratch/build/09b-zig-full.log`、`.exit` |
| Host 产品 | 28/28，exit 0；含真实 Python Host 恢复、故障隔离及容量程序 | `.scratch/build/09b-host-product.log`、`.exit` |
| 核心恢复公共路径 | 独立运行 11 个场景通过，exit 0；最终代码又由 Host 产品第 25 项执行通过 | `.scratch/build/09b-core-paths.log`、`.exit`；最终证据采用 `09b-host-product.log` |

日志保存在本机 build 目录，不作为版本化测试夹具。Host 产品日志逐场打印发布 cut、激活屏障、next IntentSequence、原订单/周期数量及投影、私有状态、核心状态 SHA256；三类摘要各自独立，不能互相替代。

## 公共路径与故障切点

入口为 `src/testing/integration/strategy_host_recovery_integration.zig`、`src/runtime/strategy_cycle_recovery.zig` 和 `python/test_strategy_cycle_recovery.py`。五种阶段均由真实 Cycle 方法产生，不直接填写阶段。核心路径使用两个账户、原始共同准入组、规范报告/Fill、Owner/Store、文件 Repository 发布和重开、ManagedHost pipe、RawIngress 穷尽重放、认证账户对账、持久 HostActivated、Gateway 与再次核心共同准入。

| 场景/合同 | 已执行证据 |
|---|---|
| 五阶段恢复，I6 | Entering、Repairing、Holding、Exiting、Reconciling 分别发布、关闭/重开文件、追赶；Keep 连续/恢复完整 payload 相等，冻结周期状态与原核心身份保持。普通切点依次为 67/97/97/100/95，激活屏障为 94/110/110/113/111。 |
| S6-C，I7 | 原目标 8、匹配一半；规范减仓 Fill 在核心产生实际修复亏损 1。恢复冻结目标仍为 4、剩余要求为 5；新激活后边界价格分别不退出/退出，真实新输出经 Gateway/Owner 回到同一周期。 |
| S6-D/E | 原 Signal/Admission pending 与已提交占用相接，消费原信号、不产生第二周期；过期机会仍保留 2/3 次已用评估和原 deadline，恢复不重建预算。 |
| S6-F/G | Maker 原生 post-only 撤单在途迟到 Fill，hedge Unknown；核心原可能量、原订单、原周期与私有取消/修复预算保留。恢复拒绝激活，不盲目重发 hedge；独立核心撤单路径继续履职。报告/Fill 顺序与经济唯一性另由既有全量核心回归及 09a 证据覆盖。 |
| S6-H，I7 | Exiting 恢复保持原首次退出原因和目标，收益下降不回 Holding；激活后的实际减险输出使用新序号并关联原周期。 |
| S6-I | 真实 Monitor InvalidLatched 与 Signal 日损失/restart 同时恢复；解除 restart 后其他原因和计数仍在。Python 全量覆盖 Warning 等模型状态。 |
| S6-K | Python 五阶段 late 输入跨原期限；核心文件链路另执行 Holding 停机到期，进入 Exiting，期限和目标不重置。UTC 未验证、回退、轮转遗失未观察区间均拒绝资格；不推测跨机剩余时间。 |
| S6-L/N | schema/hash/模型/配置不兼容、错误 activation 摘要/身份、未覆盖激活事实、缺失/冲突尾部及旧 session/activation 输出拒绝。核心恢复准入尚未经 RawIngress 完成时拒绝 Recovery.begin；恢复成功不授予开仓。 |
| S6-O，I8 | 重复绑定、超容量、非法比例/原子单位、数值溢出、不等 Holding matched_base、伪造敞口及未接纳意图拒绝；核心活动/闭合与残余归属不由私有状态改写。冷热身份验证覆盖归档空洞、更大旧序号、伪造证明及部分归档；已明确拒绝的提案与未解决提案区分处理。 |
| S6-P | Keep 精确恢复；Migrate 显式迁移模型依赖；Rebuild 仅清模型预热并加锁，保留周期、标签、目标、期限和风险。真实 Host/核心链路各运行一次 Migrate/Rebuild。活动计划改配置或改 Successor 身份拒绝；核心 cutover fence、VersionActivation、新实例拒绝继承旧周期权限及文件恢复后原经济归属均有断言。 |

Recovery 的资格由 opaque 私有状态保存；调用方不能构造或回填授权 Ticket。资格绑定当前核心屏障/CanonicalStateDigest 与独立私有 Metadata/StrategyStateDigest。持久 HostActivated 先于 Host 发布新输出，屏障、摘要、fencing 或 cutover 改变后不得复用；append/commit 故障不发布权限。重放推进私有状态和原序号但不发送历史意图。新授权不执行 EnableTrading/Resume，所有场景保持 opening=false。

## 经济证据复用与界限

I8 的费用、资金费、跨日/外部流、残余与核心闭合依赖既有核心权威，不在 Python 重建账本。相关证据为 [09a 核心验证](09a-verification.md)、[费用验证](09a-fee-verification.md)、[残余验证](09a-owned-residual-verification.md)、[残余经济验证](09a-owned-residual-economics-verification.md) 和 [整合验证](09a-integration-verification.md)。旧记录中的历史状态不覆盖当前 issue；09a 已按显式配置、默认关闭范围完成。

08 的损坏/容量/分批切点与模型确定性继续由 [真实策略 checkpoint 验证](08-real-strategy-verification.md) 和最终全量回归支撑。本记录不把单模块用例误称为每个场景均走过真实核心文件链路；上表明确区分 Python、核心链路及复用证据。

## Review

按 implement/code-review 技能对基线 `0a3b26fd349e1feb82cb35e74272a60063676e71` 至 `9d0272ea` 固定 diff 作两轴独立静态复审：

- Standards：无遗留阻断或需单列的 smell；追查资格私有化、Owner 持久提交、RawIngress、UTC、冷热身份、精确单位及输出连接路径。
- Spec：无可确认新增缺陷或范围膨胀。审查提出 Successor 断言是否位于提交之外的证据范围疑问；主代理以 `git show 9d0272ea:src/testing/integration/strategy_host_recovery_integration.zig` 核实，cutover/VersionActivation/重开断言已在该提交中，工作树干净；最终产品运行包含此断言。

审查为静态审查；测试结果来自上面的独立实际运行。收尾检查通过：新记录、相关 issue 及 map 新增/修改行的 22 个相对链接可解析，6 个变更 Zig 文件规范化换行后与 `zig fmt --stdin` 输出相同，CRLF-aware `git diff --check` 通过；四份独立退出码再次核对均为 0。未清理 map 的无关历史链接，不因文档修改重复运行全量测试。

## 未覆盖资格

无真实 Venue、Demo 或生产 canonical 日志资格；无部署或交易。未证明 Linux、其他 Python 版本、跨机可信时钟或物理断电。投影由离线夹具生成，不能替代生产 normalizer/完整币种 DTO 接线。Host 输出协议尚无任意查询/撤单 RPC；独立核心安全管理沿既有接缝执行。完整 Maker–Taker 模式、生产配置和连续运行资格仍由后续验收负责，09/10 保持未关闭。
