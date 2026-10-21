# 05 多账户共同准入验证

2026-10-22。范围：[05a](issues/05a-multi-account-authority.md)、[05b](issues/05b-joint-admission-occupancy.md)、[05 汇总](issues/05-joint-admission.md)。实现基线 `03c39944c40303f628429c43fee7a1bd7cf8f41e`，Zig `0.17.0-dev.315+5b647b792`，Windows 本机离线验证。

## 权威及兼容

完整不可变部署清单验证全局每 Asset 预算、账户切片及 `(ExchangeAccount, Instrument)` 唯一 owner。Owner 和 Gateway 分别要求外围独立 pin 的完整清单摘要；恢复不恢复进程授权锚点，新增风险/发送需重新安装可信锚点。禁止清单热替换或自动扩容。

一个 DecisionDomain 只保留一个 TradingShard、OMS、trace、ShardSequence 和 decision writer。最多四个账户的经济、余额、规则、租约、对账和历史游标按账户分区，市场数据共享；同 Venue/Instrument 的公共 mark 同时更新各经济分区。订单/命令/预留保留真实账户，Gateway 按已提交命令核对配置与周期事实。

显式 DecisionDomain 业务历史根下，组、策略意图和周期使用域级键；经济键携带账户。资金费、控制和各账户对账历史实际发布、承接、重复查证和恢复贯通。订单/Fill 仍被活动周期 pin；09a 闭合前主动拒绝回收，不能把这项保护说成多账户订单归档成功资格。

持久合同：journal **43**、state **47**、registry **41**；Core input 随 journal 演进；canonical **15**、wire **13** 保持原布局。业务根和根索引 **2**、cold candidate **3**、Gateway dispatch **9**、Coordinator snapshot **10**。旧格式严格拒绝，不猜测单账户状态的多账户迁移。Core 资金费可显式带 instrument，省略时只容许无歧义的单 swap 品种。

## 已执行证据

| 命令/日志 | 结果 |
| --- | --- |
| `zig test src/main.zig -O ReleaseSafe --stack 536870912`；`05-final-full-suite.log`、`05-final-full-suite.exit` | 最终源码 **683/683**，退出码 **0**；已确认进程结束且无残留 Zig/test进程 |
| `zig test src/main.zig --test-filter 05 -O ReleaseSafe --stack 536870912`；`05-final-targeted.log` | **25/25**，退出码 0；包含 Unknown 不重发及经济槽已满时拒绝减仓新单；最终完整回归再次覆盖 |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" build-exe src/testing/integration/strategy_host_integration.zig -O ReleaseSafe --stack 536870912 -femit-bin=.scratch/build/strategy-host-05-final.exe`，再运行 exe `python python/strategy_host.py`；`05-final-host.log` | 最终源码复验 **退出码 0**；真实 Python pipe → Gateway → 多账户 Owner/Store：2 命令、1 周期，重复无新增事实，文件关闭重开摘要相同；保留既有入口检查 |
| `python -m unittest discover -s python -p test_strategy_host_bridge.py` | **5/5**，退出码 0 |
| `05-snapshot-bound.log` | codec 全字段最大编码上界 **22,716,982 B**，低于 32 MiB 并留下超过 1 MiB 余量；3/3，退出码 0 |
| `05-typecheck.log` | 已完成一轮全源类型检查，退出码 0；最终源码由完整回归再编译 |
| scoped `zig fmt --check`、`git diff --check` | 通过，退出码0 |

所有命令使用固定 Zig；`zig` 是上述绝对路径的简写。测试栈显式设为 512 MiB，不能外推部署栈/内存资格。日志、退出状态和摘要均从实际运行核对。

首轮完整回归的4项失败已修复并由最终683/683复验：更新旧版本断言；在经济及三路径恢复相等后刷新四分片摘要；统一旧单意图的账户编码与冷历史语义；按扩展后的Gateway权限证明实际字节成本修订容量。旧单意图保留legacy OMS account=0，由单账户来源隔离；domain完整组显式使用真实成员账户。

## 公共验收覆盖

- 两账户公共 canonical bootstrap 和相同 source stream/sequence 的私有事件保持独立；A 先 Fill 后 report、B 先 report 后 Fill，唯一经济成交与订单归属经 Owner/Store、snapshot、replay 保持一致。四账户配置验证第三账户竞争与第四账户独立路由。
- 真实 Host 完整帧的账户、组合、品种、配置、激活和连续身份整体校验；Python 仅提供候选。任一腿失败不发布另一腿命令或预留。单成员不能开启域周期，旧域未配置的完整组仍整体拒绝。
- AB/AC 两种到达顺序均只有一个活动占用；订单终态及经济成交不释放周期。同账户 60+50 整体拒绝、100 预算已占70再请求40拒绝、30边界通过；两账户资金不互抵。
- Warm duplicate 无新事实；冲突身份/拒绝消费沿用持久组和成员命名空间；真实域根 lookup 检查同 command ID 不同账户和配置的隔离。账户/Venue/环境/组合/所有者错配和溢出全局预算失败关闭。
- Joint input 的全部10个 append、4个 commit 切点逐项注入故障，公共 Owner 恢复核对无半组命令、占用或预留。Checkpoint publication 失败仍保留已 commit 组；未 commit 配置 seal 无发布权限，物理孤尾保持关闭。
- 已接受周期的双撤单复用占用，在新风险背压后仍可提交。减仓按账户/品种累计未承接 Fill 的旧义务和新候选，不能靠多次 reduce-only 请求越过持仓；未确认 amend 缩量不能提前释放旧义务。
- 两账户 Unknown 状态及预留经公共 Owner 恢复保持；恢复前后均通过实际 Gateway 拒绝再次发送，模拟 Adapter 发送计数为零。Unknown、成交和终态均不释放周期引用。

| 交接项 | 本票证明范围 | 仍由后续票验收 |
| --- | --- | --- |
| I2 | Host完整组进入共同准入，两账户原子预留/命令，任一腿不合格无半组 | 第二腿发送失败后的实际执行修复、Venue资格归06/07/10 |
| I3 | AB/AC两种顺序、共享资金、持久占用、Unknown不释放 | 多进程/各Venue运行及完整策略资格归10 |
| S6-E | checkpoint后原组命令/预留/占用恢复且唯一身份保留，不产生第二组核心预留 | 真实模型信号消费、策略checkpoint联结和重新激活归08/09 |

## 容量合同与测量

清单满载为4账户/4域/128资产/512账户预算/500账户品种键/2048切片，经过17代 checkpoint，快照 **1,674,764 B**，公共恢复和重复安装保持摘要及不可变性。

运行边界通过真实 Owner 输入达到：2 个订单和命令、1 个未释放周期、每账户16个开放经济事实，部分成交后保留14个资金事实再承接剩余 Fill/report；新增周期和槽已满时的减仓新单整体容量拒绝。拒绝事实继续写至日志/trace 的新风险背压边界，快照 **1,687,474 B**，Owner 恢复及直接 snapshot restore 摘要一致。这是可达运行前沿实测，不能称作1024 live/4096 terminal同时运行资格。

新风险为 trace/pin/命令/意图各保留64槽，并保留一组完整安全历史查证的 journal 预算。每账户根据现有订单未承接义务和完整组成员预检 seen、Fill evidence、applied fills/totals、ledger、开放经济事实、native assets、instrument positions，以及 canonical ingress/deferred 容量；每待成交订单预算一条最坏 Fill（spot 16条账本，swap 12条），额外保留2条经济事实及16条账本安全空间。安全减仓可使用这些余量，但新成交义务仍须有实际空间；纯撤单不新增 Fill 预算。无限 partial Fill、无限新 ingress stream 和无限安全流均不在合同内，达到边界须维护/对账并保持关闭，不能淘汰活动引用。

精确快照 sizer 与实际 codec 共用编码路径，测试对比实测长度；全字段最大编码上界额外覆盖所有数组及 optional/union 分支。32 MiB Store 上限未扩大。上界证明硬字节容量，运行前沿实测证明公共状态及恢复；两者不能推导吞吐、RSS、常驻栈或线上资格。

Gateway 最大持久行实测 accepted 775 B、resolved unknown 825 B，加4字节长度；按全字段上界保留1 MiB元数据空间后，总发送证据上限由40,960调整为 **39,210**，最大行总计 **32,505,090 B**。accepted/uncertain共用上限；达到边界拒绝新增发送，保留已有证据。`05-gateway-budget.log` 的公共 checkpoint/恢复测试3/3、退出码0。

## Standards

双轴 code-review 的 Standards 复审未发现遗留阻塞或文档硬违规。复核账户视图异常恢复、公共 mark 广播、单 writer 共同提交、减仓义务、域级历史及对账游标恢复。Gateway 的 accepted/uncertain 共用预算，固定元数据在1 MiB内；容量降低不截断历史，V9明确拒绝旧格式。复审为源码检查，运行证据由上表单独承担。

## Spec

Spec 复审提出并已修复共享 mark、单成员新周期、撤单复用占用、账户经济容量、满载快照及减仓新单承接检查。末轮源码复审未发现新的具体阻断；最终完整回归和逐项票据已补齐。保留产品入口关闭、09a前活动引用pin和有限partial-fill承接边界。双轴均为0项遗留阻断。

## 明确未授予的资格

现有产品控制面尚无“完整部署清单 + 独立可信摘要”的发布/安装合同。此次交付 Owner/Gateway 安装与验证接口，保留生产/Demo composition 的多账户入口关闭；不新增独立 CLI，也不让测试 fixture 成为预算来源。依据已接受实现合同的缺口处理条款，记录此缺口，**deployment/production qualification=false**，实际账户和金额未选择。

接入位置是 [Owner.pinDeploymentDigest/installDeployment](../../src/runtime/demo/demo_authority.zig) 与 [Gateway.pinDeploymentDigest](../../src/execution/execution_gateway.zig)。当前 runtime 及 [Windows Demo composition](../../src/windows_demo_main.zig) 没有调用这些多账户安装入口；完整组在未配置域下继续拒绝。后续必须由现有控制面交付经过授权的完整 artifact 与独立锚点，再分别安装 Owner/Gateway，不能从输入自带摘要推导信任。

周期闭合、残余阈值与释放归09a；06/07分别证明 Venue IOC/Post-only 执行。此处不声称 Venue 原子成交、完整策略、Linux运行或生产资格；没有部署、网络下单、Demo/真实交易、清理或GitHub同步。
