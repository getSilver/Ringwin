# 07：同实例参数更新与 Keep/Rebuild

Type: task
Status: in-progress
Assignee: Codex
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

### 实现接缝

- 起点 `7386cb332d2364c7aa8596bbb0bdc6b0401c15ca`，指定工作树与现有分支内实施。复用认证 Web `/api/strategy-instances`，新增 `operation=update_config`：明确实例、预期当前 ConfigVersion、递增的新版本、规范配置字符串、完整 SHA-256 和 `Keep`/`Rebuild`。实例、定义、包、范围与预算均取原绑定，HTTP 不能替换。
- ConfigVersion 内容登记保留至多1024个版本，满时明确拒绝，不回收或换绑旧版本。候选独立持久 namespace，旧实例先在实际 cursor 发布当前 checkpoint。候选使用新 context/config 创建，再以原配置身份校验并恢复旧 payload；原 checkpoint 不被覆写。候选验证失败保留旧权限，进入排空后的失败关闭权限，无法确认切换结果时标记 unknown 并阻止按旧配置恢复。
- 兼容规则位于已签名的 `contracts/config.json` 的可选 `transitions` 字段：键仅按请求选择 `Keep` 或 `Rebuild`；每条规则明确 `mutable_config_fields` 与 `rebuild_state_fields`。未列为 mutable 的配置依赖必须精确相等。缺少所选规则即拒绝，无隐式兼容或降级。
- Keep 的 rebuild 列表必须为空，restore 后 payload 必须逐字节等于旧 payload。Rebuild 只允许改变 `contracts/state.json` 字段声明中明确 `rebuildable: true` 且同时列入 `rebuild_state_fields` 的顶层字段；其他字段按解析后的规范值精确保留。周期目标、期限、风险锁存和管理进度不得声明为 rebuildable。序号始终独立校验，不允许重置。策略通过既有 create/restore/validate 实现重建，不新增迁移 ABI；Migrate 明确拒绝。
- 候选按原事件路径无权追赶、校验私有状态与预热。原生节点检查精确当前屏障，复用 TradingPause 撤权/撤单、CutoverDrain 及节点拥有的 Venue 对账证据；缺少实际证据提供者时拒绝，不从 Web 接收对账布尔值。当前单 Host 路径排空影响整个 DecisionDomain，Web 明示范围，多实例留给10票。
- 原生单 Writer 提交既有 VersionActivationEvent，在该权威事实内更新同实例配置权限。核心经济状态、序号历史与安全锁存不重置；旧配置的品种交易权限不被自动继承为新配置授权。候选实际应用切换事实并持久发布新配置 checkpoint 后停在 Ready；必须另行 EnableTrading，仍受既有全部安全条件约束。
- Web 展示转换方式、进度、结果和失败原因。未知或失败结果不展示成功；中断于排空/提交阶段的记录在重启时保持 unknown，必须先确认原生实际版本，不能猜测回滚或复权。

验证结果与最终状态在完成全量测试及双轴复审后补齐。此票不执行凭证访问、真实 Venue/Demo 下单、发布或部署；Windows 离线证据不授予 Linux 或生产资格。

