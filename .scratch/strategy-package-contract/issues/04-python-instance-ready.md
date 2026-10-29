# 04：创建 Python StrategyInstance 并无权运行至 Ready

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [03 通过 DeployRelease 安装并登记 Python StrategyPackage](03-install-python-package.md)
Parent: [模块地图](../map.md)

## Question

如何从Web运行绑定创建一个真实Python实例，经固定API加载和预热后进入Ready？

## What to build

通过现有Web创建实例绑定，实际加载固定API、校验配置并消费规范事件；展示Ready或具体失败原因。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] Web提交明确的定义、配置内容身份、实例、VirtualPortfolio、DecisionDomain及账户/品种范围，后端校验归属和配置。
- [ ] 真实候选Host按批准的包与依赖解析入口，调用validate_config、create、on_event和validate；清洁导入路径，不联网安装依赖。
- [ ] 固定API检查输出类型、容量、完整IntentGroup与连续IntentSequence；候选输出不进入交易准入。
- [ ] 预热条件由策略合同明确；数据不足、预算耗尽、异常或无效配置不得进入可激活Ready，Web显示具体原因。
- [ ] 以最小策略完成无权加载至Ready的公共路径验收，保留真实Host证据；跨实例共存由10票扩展。

## Answer / 实现证据

待实施。

