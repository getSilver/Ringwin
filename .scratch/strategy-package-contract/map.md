# 策略包与加载合同及落地

Status: open

## Destination

建立新增策略共用的交付、加载和激活合同，并跟踪其实现与验收。Python合同已定义，后续工作已拆为02–11票；原生合同细化、加载器和发布接线尚未执行。

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

- [02 原生StrategyDefinition静态注册与构建验收](issues/02-native-definition-build.md)：无未完成blocker，尚未认领。
- [03 通过DeployRelease安装并登记Python StrategyPackage](issues/03-install-python-package.md)：无未完成blocker，尚未认领。

每次只认领一张Frontier票。02–11的ready-for-agent表示票已可供接手，仍须满足各票Blocked by；其余票在依赖完成前不属于Frontier。

## Decisions so far

- 2026-10-29：用户批准并发布02–11十张纵向实施票，首批Frontier为02/03。依赖为04←03、05←04、06←05、07←06、08←06、09←02/03/06/08、10←05/06/08、11←07/09/10；各票Blocked by以相对链接为准。保留01合同票，地图保持open；不新增横向预重构、隔离系统或恢复协议。
- 2026-10-29：补充收窄后的评审建议：最终包资格证据外置绑定；Keep复用现有API，同实例Rebuild不可表达时拒绝；激活前validate检查预热。Host加载/资源计量和既有恢复接线在实现票中明确，不新增隔离或恢复系统，也不阻塞后续拆票。地图仍为open，01的resolved仍仅表示文档交付。
- 2026-10-28：纠正将合同定义完成直接标为地图closed的状态；地图恢复open。01的resolved只记录该票文档定义交付，不关闭后续原生合同、实现或验收工作。
- StrategyPackage 是 ReleaseArtifact 内的不可变交付单元；运行账户、资金、权限与激活事实分开。
- Python 使用固定 Host 内部 API 与现有匿名 pipe 协议；原生策略继续编译到 TradingShard，不动态加载。
- v1不支持Migrate或跨实例私有状态承接；代码替换/回退使用Rebuild并要求旧实例管理责任闭合，不能由发布自动平仓。
- 新增策略、代码替换、参数更新、重启和 ForwardRollback 分别定义身份及状态转换。
- 合同包含失败关闭与验收向量；当前单二进制发布器及示例 Host 不被宣称支持通用策略包。

## Not yet specified

- 原生策略完整合同由02票细化；Host加载组织、内存计量和聚合摘要由10票落实。工期和部署实例尚未指定；任务已拆分不等于实现或验收完成。

## Out of scope

交易算法、参数自动搜索、经济资格获取、插件市场、热加载原生库、任意安装脚本和生产部署。
