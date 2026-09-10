# 03: 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断

Type: task
Status: resolved
Assignee: Codex
Blocked by: [02 让 Canonical Venue 对账推进 OMS](02-apply-canonical-reconciliation-to-oms.md)
Parent: [收口当前 main 安全与权威状态缺口](../map.md)

## Question

如何让 OMS 自己拥有 OrderIntentIdentity 的幂等语义，并保证 CancelConfirmCreate 不会绕过其他 Unknown 或 PendingCancel Order？

## What to build

让 place、amend、cancel、IntentGroup 和替代单都以稳定 OrderIntentIdentity 进入 OMS。重复身份返回原结果，冲突身份锁存失败；替代单只有在旧 Order 权威终态且整个适用范围没有阻断发送的不确定订单时才创建。

## Acceptance criteria

- [x] OMS 持久识别 StrategyInstanceIdentity 与 IntentSequence；相同身份相同内容为 no-op，相同身份不同内容产生可重放冲突事实。
- [x] IntentGroup 的首序号、连续成员和成员内容共同参与幂等验证；重复 group 不创建新 Order、Command 或 reservation。
- [x] CancelConfirmCreate 在创建替代 Order 前重新执行全局 Unknown/PendingCancel、目标 revision、累计成交和授权检查。
- [x] 替代单失败不复活旧单、不借用已释放占用，也不产生部分创建的 predecessor 链。
- [x] snapshot/recovery 保留幂等集合与 predecessor 关系；恢复后重复输入与 live 行为一致。

## Out of scope

- Venue 提供的组合 cancel-replace 或自动 amend-failure 撤单能力。
