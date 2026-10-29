# 03：通过 DeployRelease 安装并登记 Python StrategyPackage

Type: task
Status: ready-for-agent
Assignee:
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何经现有发布入口安装可信策略包，并让用户看到准确登记结果而不授予交易权限？

## What to build

从签名ReleaseArtifact验证索引、包文件及运行时，原子安装并登记定义；Web展示包身份与拒绝原因。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] 现有DeployRelease贯通签名索引、manifest、全部声明文件和固定运行时的验证、安装及登记，保留既有发布能力。
- [ ] 验证规范编码、路径、容量、完整摘要和精确兼容元组；篡改、缺文件或同身份不同内容在导入前拒绝。
- [ ] 安装失败不切换current或留下部分登记；相同命令重试幂等，版本前置条件冲突明确返回。
- [ ] Web展示真实登记身份、操作结果与失败原因；仅安装时无交易授权。
- [ ] 最终包资格证据外置认证并绑定完整包摘要；补充证据不改写已冻结包，不将存在报告等同qualified。

## Answer / 实现证据

待实施。

