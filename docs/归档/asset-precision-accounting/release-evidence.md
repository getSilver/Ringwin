# Offline release evidence

The implemented source is `521db8d13f1ba346b5815c412af060ace656b406` on `codex/asset-precision-accounting`. Documentation commits after this point do not change the sealed source inputs. Parent Spec01 is unchanged. This evidence completes local implementation tickets02-14; it grants no online qualification.

[Machine-readable source/configuration/artifact manifest](release-evidence.json) records each tracked source input SHA256, Git source tree, build.zig identity, binary hashes, actual exit codes, schemas and33 private-adapter matrix case records. The source input SHA256 is `8a5d0626a5db0300a4a7afe0e569cf081faa6b5b9de8701e5f198058c682d737`. [Requirement index](coverage-evidence.md) covers all28 Stories, D1-D8, M01-M16 and six Done requirements.

| Check | Actual result | Evidence |
| --- | --- | --- |
| Debug root contract | 424/424, exit0 | report-14-full-debug.log |
| ReleaseSafe root contract | 424/424, exit0 | report-14-full-releasesafe.log |
| Linux ReleaseSafe compile | x86_64-linux-gnu, exit0 | report-14-linux-compile.log; binary SHA in manifest |
| Windows ReleaseSafe compile | exit0 | report-14-windows-compile.log; binary SHA in manifest |
| Windows fake transport process chain | exit0; OKX offline/role ownership/durable recovery passed | report-14-windows-chain.log |
| Offline canonical fixture | exit0; same-order journal replay equivalent | report-14-offline-fixture.log |
| Four-shard entry | exit0; four shards, three recovery paths, replay has no send capability | report-14-four-shard.log |

The first full suites each passed418/421 and exposed three outdated fixtures; their failing outputs remain report-14-initial-debug.log/report-14-initial-releasesafe.log, not passing evidence. Current cancel revision, activated Simulated fixture units and current Binance error classification were repaired without weakening production guards. The final suites above ran after those repairs and the review fixes.

Standards review covered e8488457..b140fa30 and the final delta: no remaining findings. Spec review found an OKX ownership skip before exact conversion (P1) and per-execution single-limit bypass (P2). Public regressions first reproduced MissingEconomicFault. All three adapters now validate source fee/rebate/PnL before skipping ownership and distinguish single limits from balance limits; current root suites pass. A stray fixture constant edit was restored and its original cumulative Suspense test passed. Independent Sol6.1 medium reviewers performed both axes; no remaining material finding was left unresolved.

## Reproduce

Use Zig `0.17.0-dev.315+5b647b792` in the isolated workspace. These commands are offline:

```powershell
zig test src/main.zig --stack 67108864
zig test src/main.zig -O ReleaseSafe --stack 67108864
zig build-exe src/main.zig -O ReleaseSafe -target x86_64-linux-gnu '-femit-bin=.scratch/build/precision-14-linux'
zig build-exe src/main.zig -O ReleaseSafe '-femit-bin=.scratch/build/precision-14-windows-rs.exe'
& .\.scratch\build\precision-14-windows-rs.exe --windows-chain-test
& .\.scratch\build\precision-14-windows-rs.exe --offline-fixture
& .\.scratch\build\precision-14-windows-rs.exe --four-shard-acceptance
```

## Numeric/configuration contract

Decimal grammar permits an optional leading plus/minus, ASCII digits and at most one decimal point with at least one digit overall (`.5` and `1.` are supported). Whitespace, exponent notation, multiple points and non-ASCII digits are rejected. Input is at most1024 bytes. Insignificant zeros normalize before checked signed-i128 accumulation; normalized scale and rescale powers are0..38. Negative zero normalizes to zero. Signed coefficient bounds are -170141183460469231731687303715884105728 through170141183460469231731687303715884105727; configured economic bounds are narrower and remain authoritative.

USDT12/BTC9/BNB test_fixture configurations are offline examples, not production precision conclusions. Default test ranges are single/balance1e15 atoms, cumulative1e18, quantity1e9 lots, price1e11 ticks and four postings; tests additionally tighten or widen explicit definitions within checked admission. Matrix registry SHA256 includes definitions and activation barriers, and actual33 case records include decision/raw barriers and canonical/semantic digests. The source digest sentinel0x74 is explicitly a fixture identity, not external authority. Production must supply sourced definitions and pass existing admission before any account authorization.

Bounds remain finite: eight assets/account facts,32 unique economic facts and64 ledger transactions; independent cash proof accepts up to16 bill rows and four query pages. Capacity overflow is unresolved and fail-closed, never eviction of economic evidence. All rescale/product/posting/cumulative arithmetic is checked. No BigInt, remainder ledger, floating-point conversion, online rescaling, schema guessing or new control plane was added.

Current canonical/encoding=10, journal=30, state=34, registry=28, acceptance=13. Older evidence with canonical2/journal22/state25/registry19 cannot be reinterpreted using these units. Existing valid-checksummed old-state/artifact rejection and raw retention are included in the root suite. Historical audit remains read-only; missing original source is unverifiable, and corrections require separately authorized append-only records.

## Qualification boundaries and next release

CanonicalStateDigest proves ordered committed state/snapshot replay at the stated barrier. SemanticAuthorityDigest proves only supported legal permutations; it does not require different audit orders to have equal canonical digests. Private-adapter matrix transports record zero external sends; SimulatedVenue has no external transport. The real Windows offline chain also reports replay_send_capability=false.

The Windows command deliberately retains top-level windows_process_chain_verified=blocked, offline=blocked, revision=not_recorded and production_qualification=false. Its narrower OKX offline ownership/recovery result passed; the manifest externally binds the compiled binary to this source revision without changing those qualification fields. Neither compile success nor offline results close existing Windows/Linux/production qualification tickets.

OKX cash/bill evidence supports the documented bounded source interval. Binance Spot snapshots cannot prove combined-product bill scope and remain unresolved. Current Bybit nonempty UNIFIED wallet cannot prove native availability/product scope and is rejected with retained raw evidence. Simulated canonical-atom fixtures do not replace real private sources or independent account proof. See the requirement index and ticket13 for precise source boundaries.

Read-only, Demo live, Testnet and production qualification are not_run/false. Do not inherit the original rounded-fee prototype or historical online reports. Continue through the existing [.scratch/production-readiness/map.md](../production-readiness/map.md) and [Windows verification tracker](../windows-process-chain-verification/map.md), using the existing Web control plane/configuration release path. Required inputs include authoritative production AssetDefinition evidence/ranges, matching code/config/schema identity, credentials custody/fencing, source-complete per-Asset fee/bill reconciliation, and final exposure/settlement evidence. Any online order/deployment/cleanup needs fresh explicit bounded authorization; none was executed here. Parent lifecycle updates and historical economic corrections remain separate authorized work.
