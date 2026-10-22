# 闭合 Reconciler 状态转换与容量边界

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [Venue 成交与恢复安全收口](../map.md)

## Question

如何让私有流 bootstrap、稳定运行、显式对账、断线重连和失败路径具有单一可检查的状态转换合同，
并在输出容量不足时既不丢事实也不伪造 ready？

## What to build

把 Reconciler 的每个公共输入映射为明确状态转换和输出屏障：bootstrap 双读进入 ready，ready 中可
显式重启 reconciliation，期间 WS 增量缓冲并在稳定屏障后释放；重复请求、断线和失败均幂等或明确
拒绝。容量边界沿公共接缝验证，不直接锁定私有 helper。

## Acceptance criteria

- [ ] buffering 在 REST 稳定双读完成后只进入一次 ready，并留下明确屏障证据。
- [ ] ready 接收新的 account reconciliation 后进入 reconciling，而不是返回与请求无关的字段错误。
- [ ] reconciling 期间的 WS 增量有界缓冲，并只在 REST 屏障完成后按确定顺序释放。
- [ ] ready 的普通 WS report/Fill 直接进入 adapter-owned pending，不要求 Demo runner 翻译私有事件。
- [ ] 重复 reconciliation 请求要么幂等复用同一请求，要么返回稳定明确的拒绝，不产生半完成状态。
- [ ] REST、WS、解析或屏障失败进入失败关闭状态，不伪造 reconciliation 完成或继续授予新增风险能力。
- [ ] ready 断线后创建新 session 并重新 bootstrap；旧 session 的迟到事实不能越过新屏障。
- [ ] 输出容量刚好够、差一个槽位和完全满载三种边界均不覆盖、不丢弃、不重排 pending 事实。
- [ ] Debug 与 ReleaseSafe 的公共 seam 状态表测试通过，且测试名称使用领域规范词汇。

## Out of scope

- 新建通用状态机框架或替换现有 VenueAdapter seam。
- 通过扩大固定容量掩盖边界错误。

## Answer

Reconciler 的 session、双 REST 稳定轮次、ready 重新 reconciliation、Unknown、断线和失败状态已
沿 `ingestPrivateWs -> VenueAdapter.tryDrain` 接缝覆盖。ready WS 事实由 adapter-owned pending
队列翻译，未泄漏到 Demo runner。

reconciliation 的完成和失败结果在写入前先检查整组所需容量；容量不足时保留全部 pending
reconciliation/account 事实，下次 drain 重试，不清空或重排。Debug 与 ReleaseSafe 的 reconciler 和
adapter 回归通过，格式及 diff 检查通过。
