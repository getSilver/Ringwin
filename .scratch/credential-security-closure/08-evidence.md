# Native Demo account guard evidence

Completed 2026-10-19. Implementation checkpoint `f63cba83` and all subsequent red/green captures are retained. This ticket adds only [okx_demo_account_guard.zig](../../src/okx_demo_account_guard.zig) plus its issue/tests/evidence; it does not modify ticket05's runtime, entrypoints, scripts or credential modules.

## API and policy

`run(allocator, source:anytype, local_ms:i64, expected_uid_hash:[]const u8, allow_btc:bool)!void` calls only `source.get(path)![]const u8`. Expected UID hash is exactly64 hex characters, decoded and compared to SHA256 of the actual account/config UID. Source owns authentication and response storage; guard parses/validates and releases its allocator-owned response before the next GET, even though source may reuse one response buffer. There is no POST/order/cancel/transfer interface, CanonicalEvent translation, new control CLI or production admission.

The normal path requires all **16 GET routes**: public time, account config, SPOT, SWAP, isolated leverage, positions, ordinary pending, all seven algo pending kinds, full balance and BTC/USDT balance. The policy preserves old preflight and Windows funded-currency gates:

- Checked server/local timestamp difference within inclusive5000ms; invalid/overflow timestamps reject without abs/minInt or numeric overflow panic.
- Matching UID fingerprint; Read or read_only plus Trade, no Withdraw; acctLv2/net_mode; actual boolean false autoLoan and enableSpotBorrow.
- Exactly one BTC-USDT SPOT/live and one BTC-USDT-SWAP SWAP/live-or-post_only. At least one valid isolated/net matching leverage row; malformed extra rows also reject.
- Every position must be zero. Ordinary pending and conditional/oco/trigger/move_order_stop/iceberg/twap/chase lists must all be empty.
- Both balance queries require correctly shaped details and all three liability fields. Existing explicitly present **string** empty/all-whitespace liab/isoLiab/crossLiab means zero, matching the existing no-margin domain convention. Missing/non-string liabilities reject. This exception does not apply to pos or eq.
- Numeric fields otherwise use strict signed decimal lexical checks, with no float conversion/integer accumulation. Nonzero arbitrarily small decimals remain nonzero; exponent/NaN/Infinity/non-string/empty position-or-equity values reject. Nonzero eq currency is USDT only, with BTC allowed solely when caller explicitly selects allow_btc=true for an existing cleanup contract. This flag grants no write capability; Windows caller must use false.
- Every response requires string code0, array data and required field types/cardinality. Unknown/malformed data does not become a zero exposure assertion.

## Results and identity

[08-validation.json](08-validation.json) binds commands, timestamps, compiler, producer, artifacts and every retained capture/log/source identity. Final same-source tree: `a959d2646245601347b25338ba7e784a60a192db7c16434e619a6fef3dbc065b`. Guard file SHA256: `96fefc27d47d2c997e76b4015760a5b21f78107d75f19de3fa73258ab0470d45`. Full matching source archive: [08-final-source.zip](08-final-source.zip).

- Windows Debug: **10/10**, exit0; existing completed18October run was verified19October, not rerun. `runs/08-final-debug-v1`.
- Windows ReleaseSafe: **10/10**, exit0; same preserved result verified. `runs/08-final-safe-v1`.
- Linux ReleaseSafe: cross-compile exit0 and **actual WSL ELF execution10/10**, exit0, completed19October. `runs/08-final-linux-compile-v1`, `runs/08-final-linux-run-v1`. Kernel4.4.0-17763-Microsoft, uid1000. PE/ELF artifact magic and complete hashes checked.

All final captures bind the same source and have no timeout, panic, capture error or source drift. No skipped tests, .env.local read, real credential, network request or legacy preflight execution occurred.

Ten public-seam tests cover the normal16-route contract; 128 envelope rejection variants across every route; identity/permissions/modes/borrowing; uniqueness/leverage/pending states; exact clock boundaries and i64 extremes; strict zero/nonzero/underflow-like decimals; explicit blank-vs-missing liabilities; both balance views and explicit BTC exception; and all allocation failures. A reused source buffer and allocator observer enforce that previous response allocations are released before every next GET. The synthetic source exposes no write method, and rejection checks ensure no later GET is performed after a safety failure. UID expected hash is an independent Python hashlib literal, not a value computed by the guard under test.

## Retained intermediate failures

- `08-normal-red-v1`: product tracer red, NotImplemented; normal green1/1 followed.
- `08-shape-red-v1`: extra malformed leverage row was accepted after a correct row; fixed by requiring nonblank required strings, then green1/1.
- `08-blank-liability-red-v1`: initially rejected the existing explicit blank-liability convention; narrowed exception implemented only for the three liability fields, then green1/1. Missing, non-string and tiny nonzero debt still reject.
- `08-rejections-debug-v1`: test-only syntax error in repeated-digit fixture construction, fixed to bounded array initialization; v2 then10/10. This was not a product safety failure or skipped result.
- First metadata writer reached an end ancestry guard after the integration branch advanced from8c5f5980 to docs-only baf6856c. The complete source archive already existed; no validation JSON was published. Original writer retained as `08-seal-evidence-v1-incomplete.py`. After merging the docs-only tip, the updated writer verified archive members/CRC/SHA and finished metadata without overwriting the archive or rerunning business checks. This is an evidence-publication ordering event, not a test failure.

## Reproduce and remaining scope

```powershell
python .scratch/credential-security-closure/capture.py <new-debug-label> -- 'D:/Program Files/zig/zig.exe' test src/okx_demo_account_guard.zig -O Debug --cache-dir .zig-cache/credential08
python .scratch/credential-security-closure/capture.py <new-safe-label> -- 'D:/Program Files/zig/zig.exe' test src/okx_demo_account_guard.zig -O ReleaseSafe --cache-dir .zig-cache/credential08
python .scratch/credential-security-closure/capture.py <new-linux-build-label> -- 'D:/Program Files/zig/zig.exe' test src/okx_demo_account_guard.zig -O ReleaseSafe -target x86_64-linux --test-no-exec --cache-dir .zig-cache/credential08-linux '-femit-bin=.scratch/credential-security-closure/credential08-final-linux'
python .scratch/credential-security-closure/capture.py <new-linux-run-label> -- wsl.exe -- /mnt/d/github/Ringwin-credential-native-account-guard/.scratch/credential-security-closure/credential08-final-linux
```

The literal command arrays in validation JSON are authoritative; reproduction requires new labels/artifact names to preserve sealed evidence. No full repository Debug acceptance ran for this ticket. Ticket05 still owns actual protected GET source adaptation, timestamp refresh, before-first-write guard and success/failure postflight integration. Its wider lifecycle cannot be closed from these standalone synthetic results. Target OS security, real Venue/account qualification and production authorization remain separate.
