# Exact accounting requirement evidence

This is an offline requirement index, not an online qualification or a change to parent Spec 01. Final source sealing is recorded in release-evidence.json and release-evidence.md; Debug/ReleaseSafe each passed424/424 at source521db8d1.

## Evidence groups

- **amount**: src/venue_fill_recovery_acceptance.zig: OKX native settlement/base/third tests; src/native_multi_venue_accounting_acceptance.zig: native multi Venue shared matrix; src/simulated_native_accounting_acceptance.zig: Simulated native public Owner
- **config**: src/asset_registry.zig: activated source asset codes; src/trading_shard.zig: asset definition activation/idempotence/conflicts; src/demo_authority.zig: Policy activation and live-source admission
- **decimal**: src/canonical_event.zig: bounded decimal text normalizes before accumulation and preserves signed limits; src/venue_fill_recovery_acceptance.zig: long-tail WS and short REST identity
- **fault**: src/native_multi_venue_accounting_acceptance.zig: unknown/subatom/overflow, malformed frame, absent private order link, extraFees, wallet scope and conflict; src/venue_adapter_contract.zig: economic fault recovery and queue contract
- **recovery**: src/asset_precision_file_recovery_acceptance.zig: Windows native file recovery (18 interruption cases), retained committed inputs; src/demo_authority.zig: replayCommittedIngress and durable startup admission
- **quantity**: src/venue_fill_recovery_acceptance.zig: native base nonunit lot/tick, report/Fill WS/REST permutations; src/economics.zig: independent buy/sell cost, PnL, funding and forced penalty assertions
- **independent**: src/native_economic_reconciliation_acceptance.zig: independent native bill interval, one-atom mismatch, range/pagination/source conflict and unapplied Fill; src/binance_venue_adapter.zig: scoped Spot snapshots stay unresolved
- **history**: src/historical_fee_audit.zig: 3 audit tests; report-historical-offline-debug.json and report-historical-offline-rs.json; actual historical missing-source record remains unverifiable
- **provenance**: report-13-debug.log and report-13-final-releasesafe.log: activated registry hash, decision/raw barriers, canonical/semantic digests, transport sends=0; release-evidence.json: source521db8d1, exact file hashes, final424/424 suites, compile/runtime exits and no inherited qualification
- **authorization**: Tickets02-13 offline boundaries; no account connection, external messages, orders, deployment, cleanup or historical correction; online qualification not_run and production_qualified=false

## User Stories

| Story | Requirement | Evidence | Scope/status |
| --- | --- | --- | --- |
| 01 | As a SystemOwner, I want actual Venue fees recorded exactly, so that the ledger reflects real deductions. | amount | Offline supported contract |
| 02 | As a VirtualPortfolio owner, I want tiny fees preserved at the configured precision, so that many fills do not accumulate fabricated costs. | amount | Offline supported contract |
| 03 | As a VirtualPortfolio owner, I want rebates recorded separately and exactly, so that income is neither discarded nor merged into a negative fee. | amount | Offline supported contract |
| 04 | As an ExchangeAccount owner, I want fees retained in their original Asset, so that the system never silently converts them to USDT. | amount | Offline supported contract |
| 05 | As a SystemOwner, I want configured third-Asset fees supported by the same ledger, so that accounting does not depend on a base/quote-only assumption. | amount | Offline supported contract |
| 06 | As a report consumer, I want assets without a valid valuation marked unvalued, so that missing prices do not become zero-value income or cost. | amount | Offline supported contract |
| 07 | As a SystemOwner, I want distinct fills to sum to their exact Venue amounts, so that per-fill conversion introduces no cumulative bias. | amount | Offline supported contract |
| 08 | As a recovery operator, I want repeated fills to have no additional economic effect, so that replay and reconciliation cannot charge twice. | recovery | Offline supported contract |
| 09 | As a recovery operator, I want conflicting duplicate facts to fail closed, so that changed amounts cannot overwrite prior economics. | fault | Offline supported contract |
| 10 | As a SystemOwner, I want Asset precision activated through validated configuration, so that adapters cannot choose or change authoritative units. | config | Offline supported contract |
| 11 | As an auditor, I want each amount's precision interpretation recoverable from recorded versions, so that historical replay does not use current process settings. | config | Offline supported contract |
| 12 | As a SystemOwner, I want unsupported Assets and precision conflicts rejected before trading, so that the account cannot accumulate unaccountable exposure. | config | Offline supported contract |
| 13 | As an adapter maintainer, I want bounded decimals normalized before range checks, so that harmless textual zero padding does not overflow an otherwise valid value. | decimal | Offline supported contract |
| 14 | As an adapter maintainer, I want explicit finite input and arithmetic limits, so that the system does not promise arbitrary-length decimal support. | decimal | Offline supported contract |
| 15 | As an operator, I want conversion failures to identify their cause and raw evidence, so that inexact values can be distinguished from overflow and malformed data. | fault | Offline supported contract |
| 16 | As a SystemOwner, I want numeric failures to latch trading safety even without a pending reconciliation request, so that an incomplete account view cannot continue increasing risk. | fault | Offline supported contract |
| 17 | As a recovery operator, I want cancellation and reconciliation paths to remain available when safe, so that stopping new risk does not strand uncertain orders. | fault | Offline supported contract |
| 18 | As an auditor, I want unrepresentable completed trades retained as unresolved source facts, so that rejection cannot erase a real execution. | fault | Offline supported contract |
| 19 | As a recovery operator, I want bounded-buffer and storage failures to retain or recover pending facts, so that failure reporting itself cannot lose economics. | recovery | Offline supported contract |
| 20 | As a recovery operator, I want crash recovery to reconstruct the same amounts and safety state, so that restarting does not clear an unresolved numeric failure. | recovery | Offline supported contract |
| 21 | As a SystemOwner, I want replay to have no send capability, so that restoring evidence never repeats external orders. | recovery | Offline supported contract |
| 22 | As a release operator, I want incompatible historical schemas to fail closed, so that old integers are not silently interpreted using a new precision. | recovery | Offline supported contract |
| 23 | As a strategy owner, I want asset atoms, traded lots and price ticks converted explicitly, so that increasing precision does not change economic quantity or notional. | quantity | Offline supported contract |
| 24 | As a strategy owner, I want costs and PnL to retain their established rules, so that fee precision fixes do not introduce duplicate cash movements or hidden cost changes. | quantity | Offline supported contract |
| 25 | As an auditor, I want internal closure and independent Venue reconciliation both checked, so that mirrored errors cannot pass acceptance. | independent | OKX supported cash/bill proof; Binance/Bybit unsupported scope stays unresolved |
| 26 | As a SystemOwner, I want historical accounting discrepancies reported without rewriting immutable records, so that any correction remains reviewable and traceable. | history | Offline supported contract |
| 27 | As a release operator, I want multi-Venue acceptance tied to an exact source and configuration identity, so that local evidence is not mistaken for online qualification. | provenance | Sealed offline evidence |
| 28 | As a SystemOwner, I want the plan separated from trading authorization, so that publishing a Spec does not authorize orders, cleanup or deployment. | authorization | Offline supported contract |

## Implementation Decisions

| Decision | Evidence |
| --- | --- |
| D1 Ownership and minimal implementation | amount, fault: actual adapters emit canonical facts, same Owner/TradingShard; no Venue-private fields in Core |
| D2 Actual amounts and conservative estimates | amount, quantity: exact source conversion; risk reservation rounding separate |
| D3 Authoritative precision and ranges | config, recovery: activated fixed units and bounded admission; production source proof not_run |
| D4 Bounded Decimal | decimal: 1024-byte plain decimal, normalized zeros, i128 coefficient, scale/rescale 0..38 |
| D5 Unrepresentable facts and recovery | fault, recovery: raw references, durable latches, pending ingress and no replay sends |
| D6 Asset bookkeeping and independent reconciliation | amount, independent: native postings and source-qualified cash/bill proof; missing scope never heals |
| D7 Schema, history and qualification | history, provenance, authorization: immutable old evidence and no inherited qualification |
| D8 Implementation order | S1:02; S2:03/04; S3:05-10; S4:11/12; S5:13/14. Blocking edges honored; all groups and final424/424 suites sealed |

## Acceptance matrix

| Matrix | Evidence | Scope |
| --- | --- | --- |
| M01 | amount | USDT source fees 4198632165 and 4237238520 atoms at scale12; old scale6 rejects |
| M02 | amount | Ten 1e-7 USDT fees exact accumulation; old scale6 rejects |
| M03 | amount | BTC 1e-9 fee is one atom at scale9; old scale8 rejects |
| M04 | amount, fault | Fee/rebate signs, explicit zero versus missing and extra component rejection |
| M05 | amount | Base/quote/third postings; unvalued third asset remains incomplete |
| M06 | quantity | Nonunit lot/tick and sublot inventory |
| M07 | config, recovery | Activation/version conflict/idempotence and committed configuration replay |
| M08 | decimal | Zeros/signs/long tails, invalid grammar and length bounds |
| M09 | amount, decimal, fault | i128/signed magnitude/rescale/cumulative/intermediate bounds and no partial money |
| M10 | fault | Ready conversion failures without pending reconciliation; unlinked source validation |
| M11 | fault, recovery | Queue capacity and RawIngress/decision append/commit failures; durable recovery gate |
| M12 | quantity, recovery | Report/Fill order, actual WS/REST duplicates; Bybit permutations compare semantic digests |
| M13 | fault | Conflicting amount/asset/precision identity preserves original economics |
| M14 | recovery | File reopen across source/fact/fault/recovery/snapshot barriers; no sends |
| M15 | independent | Actual OKX source range/bill chain; unsupported Binance/Bybit independent scope remains unresolved |
| M16 | history | Read-only old-scale joins and fixed differences; missing actual sources unverifiable |

## Six Done requirements

| Done | Evidence | Status |
| --- | --- | --- |
| 1 S1-S5 implementation/failure/range evidence | all groups | S1-S5 offline implementation and final sealing complete |
| 2 Traceable precision; no private precision defaults | config, amount | Offline supported contract; production values require external source admission |
| 3 Exact per-Asset posting, internal closure and independent proof | amount, independent | OKX supported native cash/bill scope; other unsupported account proofs rejected |
| 4 Evidence and safety through no pending/capacity/store/restart | fault, recovery | Offline evidence |
| 5 Duplicate/conflict/order/snapshot/no-send replay | quantity, recovery, provenance | Sealed offline evidence |
| 6 Historical and qualification boundaries | history, authorization | No corrections/online writes/new qualification executed |

## Supported scope and limits

- USDT scale12/BTC scale9 and BNB test definitions are explicitly test_fixture configurations, not production decimal conclusions. Registry source hash and activation barriers are recorded in precision13 log lines.
- Plain decimal input is at most1024 bytes; coefficient is signed i128; normalized scale and rescale power are0..38. Asset admission checks each configured single/balance/cumulative/quantity/price/posting limit and checked arithmetic at runtime. No arbitrary precision or tolerance.
- OKX native cash and independent source bill proof use the existing bounded Spot/isolated-linear contract; position-cash changes lacking proof stay unresolved.
- Binance Spot free/locked may be native observations only with recorded Spot target/account scope. A Spot account snapshot cannot prove the combined-product economic scope or bill history, so scoped economic requests remain unresolved.
- Bybit current nonempty UNIFIED wallet does not prove native availability/product scope. It is retained as raw evidence and rejected durably; deprecated availableToWithdraw and USD available balances do not become native availability. Actual execution fee decoding remains covered with an explicit trusted offline core opening.
- SimulatedVenue receives canonical atoms, so source text/Decimal granularity are not applicable. Its public contract exercises the same Owner, postings and persistence but does not replace actual private-adapter or independent-account evidence.
- CanonicalStateDigest compares ordered committed audit states; SemanticAuthorityDigest compares supported legal fact permutations. Neither digest establishes online/account qualification.
- Parent Spec remains unchanged. Demo/Testnet/production qualification is not_run/false; fresh explicit bounded authorization and real final exposure/settlement evidence are required before online qualification.
