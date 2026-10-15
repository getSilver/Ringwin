# Task08 Standards review

Baseline: `b5a2d97690dc0ce1979e407694ff5d53ae2c949e`.
Frozen v3 source: `1ac484f6586253131c2f8845821d54a6d4fc2b2edb63579d0d72dd9a41d02c71`.
Read-only final delta review; every file in the v3 fixture audit source inventory matched its recorded SHA256 during this review.

No remaining confirmed P1/P2 Standards findings in the reviewed changes. Repository AGENTS/CONTEXT and ADR0011/0013–0016 take precedence over general smell heuristics. No smell-only observation is promoted to a correctness violation.

Previously reported AccountFact conflict admission is fixed: public hot/cold conflict paths close CoordinatorOwner and preserve RecoveryOnly. Live application no longer invokes the historical recovery override. Forced open facts retain the original economic input digest while the ordered Trace retains its separate input digest; strict snapshot validation remains intact. Immutable Coordinator origin binding is committed, pinned, digested, restored, and compared before cross-owner archive acceptance.

Final deltas checked:

- Coordinator and Cutover recovery close on a published history head without any committed root; they retain committed hot state and do not adopt the orphan head (`account_coordinator.zig:3062`, `cutover_history.zig:201`).
- The legacy Cutover fixture explicitly supplies the schema of its existing active release (`recovery_cutover.zig:779`). Public `recoverStableInto` verifies complete input/derived fact groups, including forced open-set commitments, while retaining digest/economics assertions (`recovery_cutover.zig:851`). This strengthens replay coverage.
- Explicit Gateway control/forced kind coverage restores accepted and Unknown wire fixtures, advances both roots, repeats acknowledgement, then restores Gateway and compares full outcomes. It makes no send calls. Its synthetic Core qualification is isolated Gateway protocol coverage, not Core closure proof acceptance (`control_gateway_retention_acceptance.zig:32`).

Fixture bounds independently checked for task08 changed/new sources: controls/cutovers create no orders; resident authorization retains one; shared routing creates and archives one before its next iteration; four forced Owners each seed one order then archive it before 320 source rounds. Quantity400 denotes lots, not 400 orders. At most four initial OMS records coexist; loops do not accumulate orders. The two Gateway wire proofs remain two dispatch records. All remain below 100 live and 100 terminal across shards.

Checkpoint/recovery loops remain present (forced/routing every four rounds, control windows and periodic checkpoints). Finite 128MiB/64MiB MemoryAdapter archive budgets fund synthetic backing history; they do not enlarge Core live/terminal arrays. The v3 fixture audit accurately distinguishes unchanged-source prior review from task08 delta review; this review does not claim a new independent audit of all 89 historical test files. Full native pipeline results remain separate acceptance evidence.
