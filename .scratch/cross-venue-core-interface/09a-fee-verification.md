# 09a independent fee adjustment verification

Implementation 2026-10-22; final targeted verification 2026-10-23. Baseline `33b12491`, branch `codex/09a-fee-adjustment`. Zig `0.17.0-dev.315+5b647b792`, Windows x86_64, 512 MiB test stack.

## Contract

`canonical.FeeAdjustment` is an independent immutable event binding the original Fill, account, portfolio, strategy and cycle, immutable original provenance, previous fee version, explicit source identity and strictly consecutive revision, new nonnegative TradingFee, raw source evidence and adjustment time. Its evidence must exactly match envelope `raw_evidence`. VenueAdapter owns private evidence translation; core verifies ownership and computes the difference. This is fee-only: VenueRebate remains independent and cannot be revised using a negative fee.

Same identity/content is inert, including revision one arriving again after revision two. Conflicts, missing predecessors, stale revisions, reused source evidence, negative fees and ownership mismatches reject without changing money and preserve the economic fault gate. A successful adjustment does not clear an earlier fault. Original Fill/fee, quantity, price, OMS cumulative quantity and unique applied Fill quantity remain immutable. Currency changes reverse the previous asset charge before posting the new asset charge in both economic layers.

Fill archive batches publish a typed `fee_origin` entry containing original canonical Fill and original ownership/cycle. For an archived Fill, Owner uses existing cold-history staging/query/proof/commit; core applies the first adjustment only after the current business root proves the supplied original provenance is the same. Missing/conflicting proof does not authorize adjustment. Ordinary Fills consume no permanent new origin capacity. Only adjusted Fill origins and revisions remain resident (32 each); capacity exhaustion rejects new adjustments and does not block ordinary safe Fill accounting. Adjustment-ledger archival is not implemented; the existing 64-transaction ledger limit remains.

Each adjustment is a distinct account-economic fact. A complete reconciliation window must cover its identity, digest, fee confirmation and adjustment time before cycle closure. A late adjustment after closure/archive retains the original cycle. Integration with the residual branch must persistently close new-risk admission when an already accepted residual belongs to the adjusted old cycle; this branch's baseline has no `Closure.residuals`, so the main window owns that hook and cross-feature acceptance.

Formats: journal/state/registry **45/49/43**, canonical **16**, StateDigestV13 / SemanticAuthorityDigestV3. Old persistence formats fail closed; no migration. The main window recaptures frozen trace digests after combined economic/recovery validation.

## Public verification

Agreed seams: `VenueAdapter.tryDrain -> Owner.applyAdapterBatch -> TradingShard.apply`, Owner/Store append/commit/checkpoint, snapshot/recovery. The adapter fixture supplies canonical evidence and does not claim real Venue decoder qualification.

- Red: the first public success vector failed compilation because `Payload.fee_adjustment` did not exist.
- Debug: `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/multi_account_authority_acceptance.zig --test-filter "09a fee adjustment" -O Debug --stack 536870912` passed **5/5** including the entry test. Covers differences, revision ordering, duplicates/conflicts, source and account isolation, unchanged original Fill/quantities, correction followed by complete reconciliation/closure, archived Fill and closed-cycle correction, cross-currency reversal, both append cuts, commit and checkpoint failures, snapshot/digest recovery.
- ReleaseSafe same five vectors: **5/5 passed, exit 0**, including the valid-revision-after-prior-fault check added after the Debug run.
- `src/testing/acceptance/history/fill_archive_acceptance.zig --test-filter "eighteen partial" -O ReleaseSafe`: **2/2 passed, exit 0**; `.scratch/build/09a-fee-18-windows.log/.exit`. Extends the existing public scenario to 18 windows / 36 canonical Fills with per-Fill archive/checkpoint/recovery and cold duplicate/conflict checks, proving ordinary Fills have no new 32-origin ceiling. The first expanded run failed only at its last consumer-risk expectation (36 versus the correct 4 remaining lots for a 40-lot order after 36 applied lots); that test expectation was corrected, and the complete expanded scenario then passed.
- `src/testing/acceptance/history/reconciliation_archive_acceptance.zig --test-filter "ten closed funding windows" -O ReleaseSafe`: **2/2 passed, exit 0**; existing continuous-window regression.

All use the same wrapper/Zig path and `--stack 536870912`. `zig fmt --check` on all ten changed Zig files and `git diff --check` passed. Full regression is reserved for the main window after both changes merge.

## Source support boundary

[IBKR CommissionAndFeesReport](https://www.interactivebrokers.com/docs/tws-api/ref/commission-and-fees-report) associates execId, charges and currency but does not establish independent fee-correction identity or consecutive revision semantics. [Execution object](https://www.interactivebrokers.com/docs/tws-api/doc/order-management/execution-details/the-execution-object) correction suffixes must not be treated as fee-only authorization. [OKX archived bills](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-3-months) provide bill/order/trade/fee/currency accounting evidence; available evidence does not establish this independent revision chain.

Current OKX/Binance/Bybit adapters do not claim to emit these adjustments. This implements the executable offline canonical input and adapter contract, adds no IBKR adapter and invents no OKX private correction protocol. See the main window's `09a-fee-source-evidence.md` for independently verified official-source evidence. No deployment, orders or external writes.
