# OKX Demo credential input

Current Zig Demo entry points accept a one-shot binary frame on an inherited anonymous pipe or socket. TTY, ordinary files, argv credentials and the legacy `RINGWIN_OKX_KEY`, `RINGWIN_OKX_SECRET`, `RINGWIN_OKX_PASSPHRASE` environment variables are rejected before transport initialization. `-EnvFile` is retired and reports an error. Do not use PowerShell text pipelines or decode real credentials into managed strings to construct this input.

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | ASCII `RWDC` |
| 4 | 1 | Version `1` |
| 5 | 1 | Environment `1` = Demo only |
| 6 | 1 | Purpose `1` = observation, `2` = execution |
| 7 | 1 | Reserved, must be zero |
| 8 | 8 | Account identity `2`, unsigned little endian |
| 16 | 6 | API key, secret key, passphrase lengths, three unsigned little endian u16 values; each 1..128 |
| 22 | sum of lengths | Three exact field byte strings, followed immediately by EOF |

The producer must close its write handle. Extra bytes, missing EOF/header/payload bytes, invalid lengths, wrong account/purpose/version and production/testnet environments fail closed. Header fields are nonsecret. Payload and the trailing-byte probe go directly into locked protected memory; the parser does not use a buffered Reader. Forwarding writes directly from that owner to an inspected pipe/socket, never a file. The native producer/provisioner supplying this stream is responsible for its own input and memory lifetime; these wrappers do not introduce another secret loader.

The Windows controller accepts observation frames for `--windows-demo-readonly` and execution frames for explicitly authorized `--windows-demo-live`. It forwards the matching frame only to execution_gateway over a dedicated stdin pipe, closes that writer before waiting for readiness, and retains its protected owner only for the independent read-only account guards. The engine receives only its separate synthetic store-fixture password. Market, telemetry and control roles receive no credential stdin. Offline ExecutionOwners do not read stdin. Restart requires another supplied frame; no secret is recovered from journal, environment or control messages.

Standalone `--prepare-only` and private smoke use observation frames. Linux `--demo-live` and `--cleanup-only` use execution frames and retain the existing versioned policy, durable authority/fence and recovery/cleanup gates. Cleanup may begin with BTC+USDT funding; ordinary startup and all successful postflight gates require USDT-only or empty funding. `CredentialStore.admitExecution` still rejects production execution. Demo pipe import is not a production store signing lease.

The four current launchers are `run-windows-demo-readonly.ps1`, `run-okx-demo-live-acceptance.ps1`, `test-okx-zig-private.ps1` and `run-okx-linux-acceptance.ps1`. They build first with a separate empty stdin for the compiler, then let the final native executable inherit the original binary handle. They never read its bytes. Endpoint/entity/UID SHA256, policy/state paths, deadline and proxies remain nonsecret configuration. Windows/Linux wrappers require explicit configured UID hash; native guards compare it against the actual account/config UID, rather than trusting the label. Fresh SystemOwner authorization and ReleaseSafe restrictions remain mandatory for writes. Windows standalone authoritative writes remain Linux-only as required by the existing runner.

Native preflight and successful/failing postflight guards use protected TransportOwner GET requests. They preserve the old managed preflight conditions: time offset within5s; actual UID hash; Read+Trade/no Withdraw; futures/net mode and borrowing disabled; account instrument availability; isolated/net leverage; zero positions, ordinary orders and seven algorithmic-order categories; full and BTC/USDT balance liabilities and funding restrictions. Any failure blocks the business operation; a failed postflight cannot produce a passed report. These raw safety assertions do not translate CanonicalEvent or grant trading authority. Canonical ownership remains in VenueAdapter.

The old `okx-demo-preflight.ps1`, `okx-demo-private-readonly.ps1`, `okx-demo-live-postonly.ps1` and `okx-demo-residual-cleanup.ps1` are explicitly retired before any EnvFile read/network call. They are not called by the protected path. Historical `.scratch` launchers, including `linux-qualification-20260921/run-okx-v7.sh`, are retained byte-for-byte as old evidence and are **not current launchers**. Their exported credential environment is rejected by current binaries. Old reports/artifacts do not qualify new source.

This input migration does not qualify production, target dump/swap resistance, process-kill wiping or TLS/OS internal buffers. No real credential or network operation is needed for its offline regression suite.
