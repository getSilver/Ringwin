# Owned residual economic consumption

2026-10-23. ADR0019 supersedes the prior age and permanently reserved-inventory policy. This record covers the economic integration; lifecycle, manual control, limits and schema ownership remain in the companion residual implementation.

## Economic ownership

Canonical Fill quantity, price, original fee/rebate, OMS reported cumulative quantity and unique applied Fill quantity retain their existing meanings. Only the core derives `economics.Fill.inventory_only_lots`, after a real canonical sell consumes enough previously accepted residual atoms belonging to the same account/portfolio/asset. The legacy `CorePayload.economic_fill` carries no such caller-controlled capability.

Receipts retain which old cycle slots supplied atoms. Economic inventory attribution moves from those original instruments to the executing instrument before the ordinary Fill debit; native balances do not move during this attribution step. This prevents a finer-lot instrument selling old residual from creating a gross short, nonzero OpenCost, negative instrument inventory, or leaving duplicate accepted inventory on the original instrument. Original acceptance records and canonical Fill ownership remain immutable.

The ordinary Fill posts the complete real cash movement once. Gross-position notional is the integer quotient of its share; the entire integer tail belongs to inventory-only proceeds, so the two components equal the original exact notional. Zero-OpenCost residual proceeds enter realized settlement PnL. Historical TradingRebate/native income counters retain their original asset units and are not posted to cash a second time. The public vector independently expects cash +1, realized PnL +1 and unchanged original base rebate.

## Fee revisions

Same-asset revisions consume or restore only the net difference. Refunds restore prior fee-adjustment receipts in reverse order, followed by the original Fill fee consumption, bounded by the original fee amount so a fee refund cannot restore trade consumption. A currency change refunds the old asset and charges the new asset independently. Restoration reattributes instrument inventory back to each supplying slot and restores its frozen allocation.

A pre-acceptance fee refund has no post-acceptance consumption receipt to restore. Its unmatched non-settlement credit uses `creditOwned` with the original fee/cycle provenance: original acceptance remains immutable, while current remaining and `credited_atoms` increase. The lifecycle validates `original_atoms + credited_atoms = remaining + net_consumption`. Missing/ambiguous slot or exhausted credit capacity retains real accounting but closes risk admission. Current aggregate limits apply to the resulting outstanding balance; credits never bypass limits.

Consumption of frozen atoms is accounted and persistently closes OMS admission. A successful refund does not automatically clear that gate. Exhausted receipt capacity cannot create fake receipts: normal accounting that can still be represented retains its risk gate; a gross-zero sale without sufficient consumption proof fails through the existing durable canonical-input/economic-fault path and remains unapplied pending evidence. This is preserved evidence and fail-closed behavior, not a claim that every unbounded sequence of real fills has been projected.

## Public evidence

Seams: Owner/Store, `Owner.applyAdapterBatch -> TradingShard.apply`, canonical inputs, checkpoint and recovery. The fixtures create accepted old cycles through actual public lifecycle inputs; tests do not write private residual slots.

- Initial public vector failed before the intended economic assertion at the old gross-zero spot-sell risk gate; the lifecycle companion repaired shared admission. Subsequent tracing exposed `InvalidEconomicFact` from prematurely giving a virgin destination instrument a base-asset identity without its unit metadata; transfer now leaves unit installation to the actual Fill.
- Final Debug: `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/accounting/owned_residual_economics_acceptance.zig --test-filter "owned residual" -O Debug --stack 536870912`: **5/5 passed, exit 0**. Logs: `.scratch/build/residual-economics-debug2.log/.exit`.
- Covers archived original Fill followed by charge/net-zero revision/refund, frozen consumption and frozen restoration, same-owner finer-lot sell without a synthetic gross position, preserved original ownership, duplicate accounting, account isolation, pre-acceptance fee refund as an original-slot credit, and checkpoint/recovery digest equality. The fee vector also executes with frozen inventory: real fees are accounted first, the risk gate persists, and refunds restore frozen allocation. The filter also includes the companion manual-freeze public vector.
- ReleaseSafe same filter: **5/5 passed, exit 0**; `.scratch/build/residual-economics-safe.log/.exit`.

After snapshot-authentication tightening, `.scratch/build/09a-owned-economics-final-safe.log/.exit` passed **6/6 ReleaseSafe, exit 0**. After the final aggregate pending-sell capacity qualification fix, `.scratch/build/09a-owned-qualified-final-safe.log/.exit` again passed **6/6 ReleaseSafe, exit 0**, including the three accounting vectors, actual public State capacity boundaries and public manual-freeze/archive/recovery vector. The companion broader 09a run passed **22/22 ReleaseSafe** before that last qualification-only fix. These are targeted results.

No full regression, frozen-digest refresh, service start, venue order, external write or Web implementation was performed by this subtask. Existing Web integration remains separate work. The joint source commit includes both agents' TradingShard hooks and EventKind registration.
