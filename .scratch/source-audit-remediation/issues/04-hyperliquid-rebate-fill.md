# 04 Hyperliquid 返佣成交贯通权威账务

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: resolved
Evidence level: producer/consumer 合同冲突已复现，F4

## Question

如何区分已知零手续费与缺失金额，让负手续费成交正确计入 rebate？

## Problem Statement

Hyperliquid 对负手续费输出 fee=null 和正 rebate，旧单测还明确要求空 fee。
TradingShard 将其判为缺失金额证据，返回 MissingFillFee，合法返佣成交无法入账。

## Solution

已知负手续费输出同一真实 Asset 的显式零 fee 和正 rebate，使原文经 adapter、核心、归档和恢复保持一致。

## User Stories

1. 作为策略所有者，我希望 maker 返佣成交入账，以免合法执行被阻断。
2. 作为账户所有者，我希望返佣保留真实资产，以免 USDC 与 USDT 混淆。
3. 作为风控负责人，我希望缺失费用仍失败关闭，以免未知金额被默认成零。
4. 作为审计者，我希望正、零、负手续费被区分，以追溯费用来源。
5. 作为恢复执行者，我希望快照与重放一致，以免返佣遗漏或重复。
6. 作为策略所有者，我希望两种报告/成交顺序均有效，以免结果依赖到达顺序。
7. 作为审计者，我希望重复成交不重复计返佣，以免账户虚增。
8. 作为维护者，我希望测试消费真实 adapter 输出，以暴露跨模块合同差异。

## Implementation Decisions

- 修正 Hyperliquid canonical 金额表示，沿用其他 Venue 已有的零 fee 与正 rebate 模式。
- 不放宽核心 MissingFillFee；原始字段缺失、资产未知、精度/金额溢出仍拒绝。
- fee/rebate 绑定原始 feeToken 对应的批准 Asset；不换币，不改变金额，不以 reported PnL 重复记账。
- 复用 Owner、EconomicProjection 和 AppliedOrderFillQuantity，不建立第二条经济路径。
- 核对原文回放、持久身份及摘要影响；按实际语义变化决定格式身份，旧证据不得无条件沿用。

## Testing Decisions

- 主要入口为私有原文 ingest → VenueAdapter.tryDrain → Owner.applyAdapterBatch → TradingShard，不能人工修正输出后再测试。
- 复用 Hyperliquid rebate fixture、共享成交恢复及经济归档公共验收。
- 覆盖正费用、零费用、返佣、缺失字段、未知资产、溢出及合法最小单位。
- 验证两种报告/成交顺序、热重复、归档后重复及冲突身份。
- 在线与 RawIngress 回放、snapshot 加尾重放比较金额、唯一应用量与 CanonicalStateDigest。

## Acceptance Criteria

- [x] 实际 adapter 返佣输出含同资产零 fee 和精确正 rebate，完整链路无 MissingFillFee。
- [x] 正费用和零费用正确；未知费用不被默认成合法零费用。
- [x] 成交与返佣只应用一次，金额、资产、订单和投资组合归属正确。
- [x] 两种报告/成交顺序通过，重复/冲突及归档后的语义正确。
- [x] 费用、唯一应用量及 CanonicalStateDigest 在合法恢复路径收敛。
- [x] 替换错误旧断言，跨 seam 最小定向回归通过，格式影响有记录；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行。

## Out of Scope

新增产品、强平成交、在线交易或按新规则回写历史账务。

## Further Notes

与 01 无必须依赖；原 Hyperliquid 模块 closed 不替代本票新增反例验收。见[审阅证据](../evidence.md)。
2026-11-04 已完成本票实施及 Debug 定向验证；模块最终 ReleaseSafe 仍 pending。

## Answer

2026-11-04 completed. Source commit: `d9e6bef8e33443ea91fade6978a1ff890d91c6c1`; baseline: `9306d06e69a5d35773784e6e066bb44a531a1a1f`. This ticket's targeted Debug checks passed; module final ReleaseSafe remains pending.

- Verified current path: raw `feeToken`/`fee` parsing in HyperliquidVenueAdapter -> VenueAdapter.tryDrain -> Owner.applyAdapterBatch -> TradingShard.apply. Negative fees now produce explicit zero fee and exact positive rebate in the original Asset. Core MissingFillFee and amount/asset validation remain enforced; reported PnL does not create another posting.
- Extended the existing recovery acceptance with positive `0.25`, zero `0`, USDC rebate `-0.001` and minimum USDC rebate `-0.000001`, each in both report/fill orders. Actual adapter output reaches the online Owner and the raw-recovery Owner without fee patching. Native consumer configuration admits the distinct USDC Asset=5. Portfolio and exchange USDC rebates are exact; settlement USDT receives no rebate. OMS reported cumulative and unique applied quantity are checked separately at100.
- RawIngress recovery and snapshot + journal tail restore converge on CanonicalStateDigest. Hot duplicates, archived original adapter batches through Owner cold history proofs, and conflicting archived fee identities preserve economic amounts; conflicts latch safety. Existing post-archive checkpoint/query recovery, digest, authority and no-resend checks remain.
- Reused the rebate case in `private-synthetic.json`: explicit zero fee and1000 rebate atoms retain USDC Asset=5. Missing fee, missing feeToken, excess precision and overflow reject; existing unknown-asset and identity-conflict checks pass.
- Format impact: private ResumeCheckpoint schema1 ->2, with explicit rejection of old seeds (`InvalidPrivateResumeCheckpoint`) tested. Cached canonical Fill semantics changed. Canonical/journal/core snapshot field layouts stay unchanged; no historical economic state is rewritten. Negative-fee RawIngress produces changed canonical content/digests under the new decoder, so prior decoder evidence cannot be reused as current qualification. Current behavior and seed incompatibility are documented in `docs/hyperliquid.md`.

Platform: Windows x86_64, Zig `0.17.0-dev.315+5b647b792`, Debug. Commands:

```powershell
python tools/zig-entry.py test src/adapters/hyperliquid/hyperliquid_venue_adapter.zig -ODebug --stack 536870912 --test-filter 'private rebate' --test-filter 'private conflicting' --test-filter 'spot execution' --test-filter 'recovery checkpoint'
python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -ODebug --stack 536870912 --test-filter 'Hyperliquid Gateway durable'
```

Both exited0:5/5 and2/2 respectively, including one shared entry test per command (five business tests total). Logs: `.scratch/build/source-audit-04-adapter-debug.log`, `.scratch/build/source-audit-04-recovery-debug.log`. Both modules are imported by `src/main.zig` and included in the final `zig build test` entry. `zig fmt --check` and `git diff --check` passed.

Red phase: old negative-fee output failed the non-null fee assertion. Initial adapter run hit the default Windows stack limit; the final targeted run uses the repository acceptance stack size of512 MiB. Fixture allocator and native consumer setup errors encountered during implementation were corrected before the final successful runs. No implementation/build/test source changed after those runs.

code-review: Standards0 findings; Spec0 findings. No full suite was run for this ticket.

Source SHA256:

- `src/adapters/hyperliquid/hyperliquid_venue_adapter.zig`: `1f15f8e65b3f58868837b4887f94c962af259e3d11211b0b8151ace5065889ca`
- `src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig`: `0a61febb92d353480c89e85a7cbd64a17bf66d59f078ddf9b4d51b0d21e3f5ae`

Not tested: final ReleaseSafe full suite (deferred until all fixes finish), live credentials, Demo/Testnet trading, target-platform power-loss or production qualification. Old-seed migration and historical accounting repair remain out of scope.
