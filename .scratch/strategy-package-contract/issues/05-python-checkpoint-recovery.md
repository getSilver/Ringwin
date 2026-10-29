# 05：Python 实例 checkpoint 与重启恢复

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [04 创建 Python StrategyInstance 并无权运行至 Ready](04-python-instance-ready.md)
Parent: [模块地图](../map.md)

## Question

如何从真实checkpoint与非空尾日志恢复同一实例，保持决定和序号连续？

## What to build

实际保存、发布、读取checkpoint，通过非空尾日志无权恢复至指定屏障，并展示恢复进度和失败结果。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [ ] snapshot的私有payload经身份、schema、cursor、内容摘要及序号检查后发布和持久保存，重启从已验证记录读取。
- [ ] 同一实例重启保留定义、配置和意图历史，HostSession按既有规则更新；非空尾日志可追赶至指定屏障。
- [ ] 同一事件流不同分批以及checkpoint加相同尾日志得到一致决定、私有摘要和next IntentSequence。
- [ ] 无权重放按相同路径消耗意图序号且零外部效果；缺checkpoint、日志缺口或不兼容schema拒绝空状态重启。
- [ ] 恢复异常后的可疑状态不发布有效checkpoint；Web可区分恢复中、Ready及拒绝原因。

## Answer / 实现证据

待实施。

