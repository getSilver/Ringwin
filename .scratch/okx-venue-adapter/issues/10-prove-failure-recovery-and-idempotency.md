# 证明断连、Unknown、部分成功与幂等恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: 09
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何以官方 Demo 能力和可审计故障注入覆盖公共/私有断连、L2 缺口、认证失败、限流、超时后受理未知、重复与乱序回报、批量部分成功、amend 并发 Fill、REST 分页及清理失败，并证明风险占用、订单身份、经济事实和恢复权限始终闭合？

## Answer

故障注入固定在既有四个产品 seam，而不是引入随机 chaos 框架：公共/私有原始入口注入版本化 venue frame，订单 dispatch 注入确定性 transport outcome，REST 对账注入逐页 endpoint observation，权威投影注入重复、迟到或冲突事实。每个 fixture 都可由名称独立运行，并同时进入 `src/main.zig` 的 ReleaseSafe/ReleaseFast 总测试集。

| 故障 | 可审计证明 | 失败关闭结果 |
|---|---|---|
| 公共断连、L2 缺口、重复及乱序 | `book duplicates are idempotent and gaps require a fresh snapshot`、`conflicting duplicate and out-of-order book updates fail closed`、`empty same-sequence update is heartbeat and resubscribe blocks deltas` | 撤销行情健康；重新 snapshot 前不接受 delta |
| 私有断连、认证失败 | `private snapshots and two stable REST reads open then disconnect revokes barrier`、`unified private WS ingress rejects a nonzero venue event after raw commit` | RawIngress 先落证；撤销新增风险就绪并重新对账 |
| 限流及 batch 部分成功 | `bounded scheduler prioritizes safety batches and charges every item`、`batch response is itemized and transport ambiguity makes every item unknown` | 每项独立记账；未发送、已提交与 Unknown 不互相覆盖 |
| 超时后可能已受理 | `Unknown requires stable rebootstrap and an explicit reconciliation result`、`uncertain submission and rejected cleanup are never replayed automatically` | 风险占用与订单身份保持；只有 found live、found terminal 或 ConfirmedAbsent 可关闭 Unknown，禁止自动重发 |
| amend 与 Fill 并发 | `queued amend is revalidated after a concurrent fill before dispatch` | dispatch 前重读当前累计成交及 revision；旧 amend 稳定落为 NotSent |
| REST 分页 | `REST pagination requires the exact descending endpoint cursor`，以及 Demo acceptance 的真实九端点分页驱动 | orders 只使用 `ordId`、fills 只使用 `billId`；缺失/跳跃游标、超过 32 页或读取不完整均不开放屏障 |
| 迟到回报、重复经济事实 | `late execution report cannot regress a terminal order`、既有 fill identity 与 stable replay 测试 | 终态不可回退；fill 仍按 `(instId, tradeId)` 幂等，REST `billId` 只做交叉校验 |
| 清理被拒或结果不确定 | `uncertain submission and rejected cleanup are never replayed automatically` | cleanup 同样只提交一次；拒绝保留 venue 事实，传输不确定进入 Unknown，均不自动重试 |

订单调度新增最小 `GuardSource`：命令离队、消耗限流预算和调用 transport 之前重新读取 TradingShard 当前权威 guard，因此排队期间发生 Fill、revision 变化、deadline 到期或资格撤销都不会穿透发送边界。Unknown 进入时会立即撤销恢复屏障并要求九端点重新取得两轮稳定读；稳定 REST 快照本身不能猜测 Unknown 已关闭，必须再提交显式 reconciliation result。这使风险占用的释放权限仍只属于权威对账，而不是 transport 或测试程序。

Demo acceptance 的 REST bootstrap 已从“每端点假定单页”改为实际驱动 `after` 游标：orders endpoint 跟随 decoder 验证过的最旧 `ordId`，fills endpoint 跟随最旧 `billId`，每页固定 20 行，短页封口，32 页上限后失败关闭。`-PrepareOnly -Optimize ReleaseSafe` 已在 Demo 环境重新通过 `private_stream`、`bootstrap`、`baseline` 和 `strategy_order_command`，全程 `writes=0`；本票不需要制造真实交易或破坏连接。

最终 48 项 `zig test src/main.zig` 在 ReleaseSafe 与 ReleaseFast 全部通过，`x86_64-linux-gnu` ReleaseSafe 离线核心交叉构建也通过。矩阵证明的是确定性恢复权限、身份和经济幂等，不把随机时序成功率误当作协议资格；整波单命令与汇总构建证据由第 11 票统一关闭。
