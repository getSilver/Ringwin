# 03：增量盘口失效与重同步闭环

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 双边多档快照](02-depth-snapshot.md)
Parent: [模块地图](../map.md)

## Question

盘口增量异常时，如何停止使用不可信深度并通过有效重同步恢复资格？

## What to build

从公共行情适配输入到 Host 可见状态贯通增量更新、失效及重同步，使实时与重放路径采用一致资格。

## 完成条件

- [x] 明确增量有序应用、档位删除、重复一致与重复冲突的行为。
- [x] 覆盖缺口、乱序、无数量、截断、规则版本切换和溢出；相关新增风险在重新合格前关闭。
- [x] 重同步快照与并发增量有明确接续规则，不能跳过缺失历史或回填过去的策略决定。
- [x] 经 MarketFeedAdapter 到 StrategyInputBatch 的公共路径验证失效、恢复及再次失效。
- [x] 捕获和重放在各异常切点产生一致盘口与资格，补齐 I1；记录兼容策略及实际验证证据。

## Answer

已完成连续深度、失效与重同步闭环。OKX MarketFeedAdapter 维护有界档位并输出规范增量完整 postimage；核心校验前驱、规则、深度、可见时间及现有 i64 范围，异常撤销资格。gap 后仅由更晚有效快照恢复，不缓存补写历史决定。最后增量判定状态进入快照和 CanonicalStateDigest。

合同：[增量深度及重同步](../../../docs/depth-resynchronization-contract.md)。验证：[03 离线验证记录](../03-verification.md)。最终 ReleaseSafe 659/659、Python 5/5；Standards / Spec 双轴复审无遗留阻塞项。Canonical/codec/journal/state/registry 为 15/13/42/46/40，旧不兼容编码精确拒绝。

I1 仅关闭本票的连续盘口与恢复子要求；任务 10、真实策略模型、其他 Venue、线上及执行模式资格独立验收。未授权或执行部署、真实或 Demo 交易。
