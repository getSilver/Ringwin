# 07：同实例参数更新与 Keep/Rebuild

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [06 显式 EnableTrading 接通策略输出与核心准入](06-enable-trading.md)
Parent: [模块地图](../map.md)

## Question

如何更新参数而保留同一实例的意图分配及存量管理责任？

## What to build

贯通Web参数提交、候选验证、排空、状态转换及停在Ready的路径，复用固定API处理受支持的Keep/Rebuild。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] 新ConfigVersion绑定认证配置字节及完整摘要；相同版本不同内容拒绝，实例与定义身份不变。
- [ ] Keep按声明兼容规则验证新旧依赖，使用新配置create、旧payload restore、无权追赶和validate；恢复不能覆盖新配置。
- [ ] 同实例Rebuild仅支持在策略合同中可通过现有API表达的保留与重建规则；不能保留意图序号和管理进度时明确拒绝。
- [ ] 成功切换保留原意图序号空间、存量管理进度和风险锁存，不放宽原周期目标或期限；切换后停在Ready等待显式启用。
- [ ] 验收兼容Keep、受支持Rebuild及不支持转换的拒绝路径，Web展示转换方式和结果；v1拒绝Migrate。

## Answer / 实现证据

待实施。

