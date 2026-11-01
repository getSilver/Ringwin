# 策略包与加载合同及落地

Status: open

## Destination

建立新增策略共用的交付、加载和激活合同，并跟踪其实现与验收。Python合同已定义，02票的原生构建合同、静态注册与构建清单及03票的Python包安装登记已交付并通过各自离线验收；04的Windows无权加载及Host资源路径已独立验收，05的Windows checkpoint持久发布与无权重启恢复、06的显式启停与核心/Gateway准入、07的同实例参数更新与Keep/Rebuild、08的代码替换与ForwardRollback创建StrategySuccessor已完成Windows离线验收，09原生统一发布与激活、10多个Python实例与共享Host生命周期已完成Windows离线验收，11仍待实施。Linux Host资源及共享总预算路径单独保留缺口。

## Definition of done

- 包内容、身份、入口、配置与权限边界明确。
- 加载、恢复、切换和回退有可检查的成功及失败结果。
- 对照当前源码，区分已有组件与待实现接缝。
- 原生策略的注册、构建清单和发布验收合同完成细化。
- 合同落地任务完成拆分，相关加载器、Host与Web发布接线有实际实现及验收证据。
- 地图仅在上述范围完成后关闭；合同成文不能代替实施或验收，真实运行资格另列证据，缺失时不得声称通过。

## Rules

- 2026-10-28 用户要求定义所有策略共用的策略包与加载合同；本次只写合同与术语，不实现或部署。
- 2026-10-29 用户确认02–11拆分，发布本地任务及依赖；本次不认领实施，不执行真实交易或部署。
- 使用根级 GLOSSARY.md 和现有 ADR；复用现有 Web 控制面、ReleaseArtifact、HostSupervisor 与核心权限。
- 不创建 GitHub Issues，不新增独立控制面 CLI，不把夹具或文档当作真实运行资格。

## Route

1. [策略包与加载合同 v1](issues/01-package-and-loading-contract.md)
2. [02 原生 StrategyDefinition 静态注册与构建验收](issues/02-native-definition-build.md)
3. [03 通过 DeployRelease 安装并登记 Python StrategyPackage](issues/03-install-python-package.md)
4. [04 创建 Python StrategyInstance 并无权运行至 Ready](issues/04-python-instance-ready.md)
5. [05 Python 实例 checkpoint 与重启恢复](issues/05-python-checkpoint-recovery.md)
6. [06 显式 EnableTrading 接通策略输出与核心准入](issues/06-enable-trading.md)
7. [07 同实例参数更新与 Keep/Rebuild](issues/07-config-transition.md)
8. [08 代码替换与 ForwardRollback 创建 StrategySuccessor](issues/08-successor-rollback.md)
9. [09 原生策略接入统一发布与激活路径](issues/09-native-release-activation.md)
10. [10 多个 Python 实例共存与共享 Host 生命周期](issues/10-multiple-python-instances.md)
11. [11 冻结合同落地的端到端验收证据](issues/11-end-to-end-evidence.md)

## Frontier

- [11 冻结合同落地的端到端验收证据](issues/11-end-to-end-evidence.md)：07/09/10已完成，可接手；尚未认领或实施。

每次只认领一张Frontier票。尚未实施票的ready-for-agent表示票已可供接手，仍须满足各票Blocked by；其余票在依赖完成前不属于Frontier。

## Decisions so far

- 2026-11-01：10完成Windows多实例共享解释器、按包模块表、独立checkpoint与会话、完整集合SHA-256和Job总提交内存预算；Web展示实际成员与域内切换范围。同节点两个策略绑定分别显式启用、完整IntentGroup输出及迟到拒绝、目标参数/代码替换与其他成员原仓库恢复均有验收。复审发现并修正双管理写死锁、慢候选持父锁与并发停用状态覆盖，三个有界真实Web回归通过。实施 `3dabcab2`、修正 `95c0c043`；最终Python341项327通过14平台skip、ReleaseSafe核心825/825、发布9/9、节点3/3，双轴最终0项；首次失败、日志警告及真实退出码原样保留，详见[10验证说明](evidence/10-validation.md)。10 resolved并移出Frontier，11可接手但未认领；地图保持open。Linux共享总预算路径尚未实现且明确拒绝，不扩张既有Linux资源、真实Venue、部署或生产资格。

- 2026-11-01：09完成原生v2签名发布/共同索引、Web绑定、实际运行二进制与静态清单核对、节点内观察入口及共同显式启用。替换与签名ForwardRollback使用Successor、责任闭合和持久激活回调，未知ACK禁止恢复旧身份。补齐现有role服务的根级ringwin入口，两个安装路径均来自相同签名字节。最终Windows Python327项313通过14平台skip、ReleaseSafe核心824/824、发布9/9、节点3/3、原生构建回归8/8，最终双轴复审0项。详见[09验证说明](evidence/09-validation.md)，保留核心日志异常文字与真实退出0。09 resolved并移出Frontier，10可接手但未认领；完整日志恢复、单实例和观察输出合同不扩张，节点重启、磁盘/热备、Linux、实际Venue及部署/生产资格未取得，地图保持open。

- 2026-11-01：08完成Web代码接替、旧定义ForwardRollback、新Successor无权Rebuild及原生责任闭合/版本激活。保持原组合、资金、历史与风险约束；旧身份封住，成功后Ready等待显式启用，排空后未知结果禁止旧实例恢复。Windows Python最终320项306通过14平台skip；ReleaseSafe核心824/824、原生构建9/9、最终验收节点3/3、核心专项4/4，UI/静态检查及双轴修正复审通过。编辑器崩溃中断不计通过，源码/二进制身份核对后重跑的两套全量均退出0；详见[08验证说明](evidence/08-validation.md)。08 resolved并移出Frontier，09/10可接手但未认领；地图保持open，单Host/DecisionDomain排空及有界身份容量保留，Linux资源、实际Venue、部署与生产资格不扩张。

- 2026-10-31：07完成Web参数提交、签名合同兼容校验、独立候选checkpoint、同实例Keep/受支持Rebuild、排空与原生版本激活，成功后停Ready等待显式启用。保留意图序号、管理进度、周期目标/期限及风险锁存；拒绝Migrate、配置换绑、不支持转换与未完成订单，未知切换不按旧配置恢复。Windows Python最终316项302通过14平台skip；ReleaseSafe核心822/822、正常构建9/9、原生验收节点构建3/3、核心专项2/2，UI/静态检查及双轴复审通过。实现提交 `cc81feee`、`a32761af`、`e500d76e`；验收与中间失败见[07验证说明](evidence/07-validation.md)。07 resolved并移出Frontier，08未认领；地图保持open，单Host排空仍覆盖DecisionDomain，不扩大Linux资源、真实Venue、部署或生产资格。

- 2026-10-31：06完成现有Web显式授权、HostActivated实际应用ACK、真实单笔/完整组输出与核心/Gateway准入，以及无权追赶、停用、安全门关闭和迟到输出拒绝。Windows Python最终306项292通过14平台skip；ReleaseSafe核心821/821、正常构建9/9、原生验收节点构建3/3，UI/静态检查通过，双轴复审0剩余发现。验收与中间失败修正见06验证说明。06 resolved并移出Frontier，07/08可接手但未认领；地图保持open，Linux资源、实际Venue、生产与部署资格不扩张。

- 2026-10-31：05完成Windows checkpoint持久发布、同实例重启、非空尾日志无权恢复及Web进度/失败接线。保留原绑定和意图历史，共享Host generation持久递增；覆盖首次/后续未确认发布的仅尾日志恢复、完整决定一致性、损坏/schema/缺口拒绝及70 KiB私有状态。Python最终299项285通过14平台skip；已有核心测试二进制821/821、checkpoint专项ReleaseSafe84/84、最终构建9/9。首次整波命令exit1且无详细诊断的日志保留，不作为通过；后续完整二进制运行及源归属见05验证说明。双轴修正复审0项剩余发现。05 resolved并移出Frontier，06可接手但未认领；地图保持open，Linux资源、生产/交易/部署资格未扩张。

- 2026-10-30（Windows补齐验收）：用户要求“补齐并验收04的Windows路径；满足条件后即可开放05”。按ADR0010独立验收，撤销此前把Linux通过作为Windows后续门槛的说明。`10713655` / `275d700c` 补齐签名Windows安装、只读ACL/junction校验、Job硬内存预算、匿名pipe外部时限及创建期/Ready后后端死亡回收。Windows Host最终27项26通过1Linux专项skip，Python全量288项274通过14平台skip，Windows签名发布3/3，原生ReleaseSafe9/9；Linux发布回归12通过3Windows专项skip，仅属发布回归。双轴复审的启动孤儿窗口已原子入组修正，复审0阻塞。04 resolved并移出Frontier，05可接手但尚未认领/实施；地图保持open。Windows结果不代替Linux资源验收，也不授予生产、交易或部署资格。

- 2026-10-30：04在统一worktree完成Web绑定、签名runtime候选加载、固定API、无权预热、批次无关、私有状态往返与Host死亡/停止接线，初始提交 `1e05071d`，修正至 `a15d016f`。旧WSL1的真实Host功能验证发现内存反向向量失败；最终增加实际RLIMIT_AS分配探测，当前平台在启动策略前拒绝。用户确认先提交实现、04保持未验收；完整Host资源向量须在真正实施硬限制的Linux补齐，04维持in-progress，地图open，05不开放。详细通过、失败及平台skip边界见04，未取得交易/部署或生产资格。

- 2026-10-30：按用户要求，将02、03及既有控制面依赖统一到 worktree `D:/github/Ringwin-strategy-package-03`、分支 `codex/strategy-package-03`，合并提交 `5e7defb5`；两个源分支均为该提交祖先，后续以此统一入口继续。适配当前核心目录、CanonicalEvent、规范genesis与回放；保留残余冻结命令7/8，追加KillSwitch为9，控制通道两端同步为v2并拒绝v1。历史工作树保留，原有未提交改动未动；04尚未认领，地图保持open。合并验收补充见03票末尾。
- 2026-10-30：03完成。实现分支 `codex/strategy-package-03-control-plane` 提交 `0f558022`、`d8774609`；票据分支 `codex/strategy-package-03` 保留02及main文档。交付签名Python包验证、原子安装/登记、Web结果和外置资格证据绑定；Python全量15/15、旧控制面Zig108/108及发布/认证回归通过，双轴复审0项。旧整波测试因基线已有普通命令默认过期时间导致的幂等缺陷失败，具体复现与边界见03；不能声称整波或真实运行资格通过。未导入策略、创建实例或授予权限。03移出Frontier，04可接手但未认领，地图保持open。
- 2026-10-30：02票在独立 worktree `D:/github/Ringwin-strategy-package-02`、分支 `codex/strategy-package-02` 完成。交付原生静态注册、独立构建清单和最小观察策略；构建验收8/8（12个正反向向量），Debug与ReleaseFast全量均820/820通过，Standards/Spec及测试栈修正复审均0项发现。原生发布与激活仍由09票接通；未执行Demo、部署或Linux运行资格验收。02移出Frontier，03尚未认领，地图保持open。
- 2026-10-29：用户批准并发布02–11十张纵向实施票，首批Frontier为02/03。依赖为04←03、05←04、06←05、07←06、08←06、09←02/03/06/08、10←05/06/08、11←07/09/10；各票Blocked by以相对链接为准。保留01合同票，地图保持open；不新增横向预重构、隔离系统或恢复协议。
- 2026-10-29：补充收窄后的评审建议：最终包资格证据外置绑定；Keep复用现有API，同实例Rebuild不可表达时拒绝；激活前validate检查预热。Host加载/资源计量和既有恢复接线在实现票中明确，不新增隔离或恢复系统，也不阻塞后续拆票。地图仍为open，01的resolved仍仅表示文档交付。
- 2026-10-28：纠正将合同定义完成直接标为地图closed的状态；地图恢复open。01的resolved只记录该票文档定义交付，不关闭后续原生合同、实现或验收工作。
- StrategyPackage 是 ReleaseArtifact 内的不可变交付单元；运行账户、资金、权限与激活事实分开。
- Python 使用固定 Host 内部 API 与现有匿名 pipe 协议；原生策略继续编译到 TradingShard，不动态加载。
- v1不支持Migrate或跨实例私有状态承接；代码替换/回退使用Rebuild并要求旧实例管理责任闭合，不能由发布自动平仓。
- 新增策略、代码替换、参数更新、重启和 ForwardRollback 分别定义身份及状态转换。
- 合同包含失败关闭与验收向量；当前单二进制发布器及示例 Host 不被宣称支持通用策略包。

## Not yet specified

- 原生构建合同见02票；09已接通统一发布与激活，10已落实Windows多实例Host加载组织、预算映射和聚合摘要，冻结版本的完整端到端证据由11票汇总。Linux共享总预算路径尚未实现，单实例资源验收仍需真正实施RLIMIT_AS的内核，当前WSL1保持拒绝。工期和部署实例尚未指定；合同或构建交付不等于运行资格完成。

## Out of scope

交易算法、参数自动搜索、经济资格获取、插件市场、热加载原生库、任意安装脚本和生产部署。
