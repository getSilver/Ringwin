# 09：原生策略接入统一发布与激活路径

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 原生 StrategyDefinition 静态注册与构建验收](02-native-definition-build.md)、[03 通过 DeployRelease 安装并登记 Python StrategyPackage](03-install-python-package.md)、[06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)、[08 代码替换与 ForwardRollback 创建 StrategySuccessor](08-successor-rollback.md)
Parent: [模块地图](../map.md)

## Question

如何把静态注册的原生策略接入共同发布和运行生命周期，而不经过Python加载器？

## What to build

将原生定义接入共同发布索引、Web实例绑定、显式启用及版本替换，核对运行身份与构建清单。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] 依据02原生合同接通共同发布索引与构建清单，必要格式差异显式版本化并拒绝不兼容内容，不将原生入口交给Python。
- [x] Web可选择原生定义并绑定实例；节点核对实际静态注册、批准构建和运行身份一致。
- [x] 原生策略复用共同归属、Ready/EnableTrading、安全条件和核心准入，不另建授权通道。
- [x] 原生代码替换及ForwardRollback按Successor、责任闭合、持久激活和显式启用规则执行。
- [x] 受控环境验收安装至启用、替换及回退路径；清单/运行身份不一致时拒绝，不支持动态库热加载。

## Answer / 实现证据

2026-11-01：在统一工作树 `D:/github/Ringwin-strategy-package-03`、分支
`codex/strategy-package-03` 完成，基线 `0f626361450460878fd8d4db8275d75799975a77`。

- 签名 `strategy_bundle_v2`、索引v2与02构建清单接通现有发布安装及共同登记；Python v1不变。
  节点核对实际运行二进制SHA-256、编译器、target、优化模式和完整静态注册。
  原生安装视图从同一签名字节派生根级ringwin入口，复用现有role服务路径并同时封存/校验。
- Web可选择原生定义并预填不可变绑定。现有归属、预算、Ready、签名EnableTrading、
  共同屏障与SafetyGate继续生效；原生Config/State和观察回调在节点Writer内执行，不进入Python。
- 代码替换及签名发布ForwardRollback创建新Successor，复用排空、责任闭合、持久激活回调、
  旧身份封锁和显式重新启用。已提交切换ACK丢失时保持unknown，禁止旧实例恢复。
- 最终Windows Python 327项，313通过、14平台skip，退出0；ReleaseSafe核心824/824、
  发布构建9/9、节点构建3/3、原生构建回归8/8；UI、静态检查和最终双轴复审通过。
  核心日志的独立failed-command标注与成功汇总、退出0均保留，没有把异常文字隐去。

详细命令、身份、初始/最终全量结果及中间失败见[09验证说明](../evidence/09-validation.md)。
本票仅完成Windows离线受控验收。原生v1只支持已登记观察入口，无订单输出；参数转换拒绝，
恢复要求完整已提交日志。后端重开不等于节点进程重启；磁盘断电、热备、实际systemd、
Linux资源、真实Venue、部署和生产资格未验收。地图保持open，10仍待实施。

