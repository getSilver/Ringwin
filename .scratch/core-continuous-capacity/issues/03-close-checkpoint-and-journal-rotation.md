# 03: 贯通检查点、日志轮转与崩溃恢复

Type: task
Status: in-progress
Assignee: Codex
Blocked by: [02 分离权威屏障与内存 Trace 下标](02-separate-authoritative-barrier-from-trace.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何同一分片跨多轮检查点继续处理权威输入，崩溃后从完整历史承接恢复，不再受驻留 Trace 和 manifest 累计上限限制？

## What to build

同一分片跨多轮检查点继续处理权威输入，崩溃后从完整历史承接恢复，不再受驻留 Trace 和 manifest 累计上限限制。

## Acceptance criteria

- [ ] 贯通输入提交、检查点、segment/manifest 轮转、快照发布和尾部恢复；历史摘要、归档引用和权威序号连续。
- [ ] 旧段只有在完整恢复/审计/查证所需替代证据已持久提交后才可回收；发布与删除顺序有明确原子性合同。
- [ ] 在各提交边界注入崩溃、短写、同步失败、磁盘满与损坏；恢复接受完整旧状态或完整新状态，缺段/混合状态失败关闭。
- [ ] 通过公共 apply/snapshot/restore 与 Store 接口验证多轮轮转、重复恢复、摘要一致和恢复零发送；可在小容量参数下独立演示。
- [ ] 驻留窗口、manifest 和恢复缓冲有界；文件系统特定证明留给票 10/11，不能以内存适配器结果代替。

## Evidence

尚未执行。仅在全部 Blocked by 任务完成后进入 Frontier；
完成时填写当前源码身份、复现入口、实际结果和剩余范围，不沿用历史测试计数或资格。

## Out of scope

用户已授权本票本地实现；不包含部署、真实 Demo/Testnet/生产下单，
也不自动授予平台或 Venue 生产资格。
