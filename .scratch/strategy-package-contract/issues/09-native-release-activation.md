# 09：原生策略接入统一发布与激活路径

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 原生 StrategyDefinition 静态注册与构建验收](02-native-definition-build.md)、[03 通过 DeployRelease 安装并登记 Python StrategyPackage](03-install-python-package.md)、[06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)、[08 代码替换与 ForwardRollback 创建 StrategySuccessor](08-successor-rollback.md)
Parent: [模块地图](../map.md)

## Question

如何把静态注册的原生策略接入共同发布和运行生命周期，而不经过Python加载器？

## What to build

将原生定义接入共同发布索引、Web实例绑定、显式启用及版本替换，核对运行身份与构建清单。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] 依据02原生合同接通共同发布索引与构建清单，必要格式差异显式版本化并拒绝不兼容内容，不将原生入口交给Python。
- [ ] Web可选择原生定义并绑定实例；节点核对实际静态注册、批准构建和运行身份一致。
- [ ] 原生策略复用共同归属、Ready/EnableTrading、安全条件和核心准入，不另建授权通道。
- [ ] 原生代码替换及ForwardRollback按Successor、责任闭合、持久激活和显式启用规则执行。
- [ ] 受控环境验收安装至启用、替换及回退路径；清单/运行身份不一致时拒绝，不支持动态库热加载。

## Answer / 实现证据

待实施。

