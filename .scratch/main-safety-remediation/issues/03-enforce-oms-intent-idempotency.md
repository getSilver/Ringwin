# 03: 闭合 OMS 意图幂等与 CancelConfirmCreate 阻断

Type: task
Status: resolved
Assignee: Codex
Blocked by: None
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

## Answer

OMS 在新风控前按原始 IntentGroup 内容判定身份，重复请求不产生命令或占用；同身份冲突提交独立、可重放的 `oms_intent_conflict` 事实。CCC 在旧单权威终态后重新核对全局不确定订单、目标 revision、累计成交及当前授权；不合格的替代请求被丢弃，旧单终态不回滚。

## 2026-09-23 复核与重开

旧 Answer 仅为历史记录。[修复计划 R03-A–C](../review-repair-plan-2026-09-23.md#03意图幂等和取消阻断)要求补证：重复意图在新风险准入前成为 no-op；同身份异内容提交可重放冲突事实；部分成交不得清除 PendingCancel 阻断。真实 Canonical CCC 入口还受 02 阻塞。

## 2026-09-24 收口证据

- R03-A：`Oms.groupIdentityStatus` 使用 StrategyInstanceIdentity、连续序号、组首序号、组大小、政策和成员内容判定 fresh/duplicate/conflict；`TradingShard` 在风控前调用。Host place 的身份按原始请求价格生成，规则/额度变化不使重复请求重新准入；持久 `applyStable` 对原样重复直接 no-op。
- R03-B：同身份异内容进入 `oms_intent_conflict` trace，连同原始 group 输入写入稳定 journal；不建立新的 Order、Command 或 reservation。live、journal replay、snapshot restore 后的重复与冲突结果一致。
- R03-C：取消待决期间收到 accepted/partial/amended 报告或 FoundLive 对账仍保持 PendingCancel；CCC 在另一个 Unknown/PendingCancel 存在时丢弃 replacement。替代单保存目标 revision 与累计成交屏障，期间出现新成交则放弃创建；`Oms.confirmReplacement` 按候选副本原子提交，风控和授权仍在终态之后重验。
- 验收：`zig test src/main.zig -ODebug` 273/273，`zig test src/main.zig -O ReleaseSafe` 273/273，`zig fmt --check` 和 `git diff --check` 通过。固定轨迹摘要随幂等身份语义更新。HEAD `0d71e8e3cdd66d05303e0dd98e8c2e51f37eb690`；8 个核心源码文件 `git diff --binary` SHA-256：`da22bed20d4973b1362760f639308acc0b1959998858b18e04bfbbc7f57aac04`。工作树有先前相关修改，未提交。
- 持久格式：journal schema 16、state schema 18；旧持久流按本图规则失败关闭，不自动迁移。本票只声明离线验收，不提升 Demo/Linux/生产资格。

## 2026-09-24 差异摘要复核

- 上述 273/273 和 state schema 18 是此前包含其他工作树测试的历史快照。提交前复核将 OMS 意图内容摘要从截断的 64 位改为持久保存 128 位，state schema 升为 19；当前候选提交的 Debug/ReleaseSafe 各 269/269。8 文件旧哈希包含 02 和更早的同文件修改，不能作为 03 独立补丁身份。用户已允许所需依赖一并提交，Windows 验证链仍留在工作树。
