# Final review resolution (task 06)

Both independent axes reviewed `c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864...2fb36708d4f7b6cac448eff01bce58651da32333`; original command/commit context remains in `06-review-context.json`. Byte-preserved reports are `06-review-original-standards.md` and `06-review-original-spec.md`.

The Standards and Spec P2 describe the same confirmed runtime defect. `Invoke-EmptyInputNative` now publishes the completed `Diagnostics.Process.ExitCode` to `$global:LASTEXITCODE` immediately after waiting, before captured output returns or a nonzero exit throws. This matches existing wrapper global exit-state semantics and lets the unchanged public `verify-okx-demo-wave.ps1` version check observe this compiler invocation.

Standards found no additional documented-standard breach. Spec found no additional substantial missing behavior or scope creep. The optional repeated protected password acquisition in `credential_store.zig` is explicit, correct ownership and nonblocking; retained unchanged to avoid an unrelated security refactor. No store changes are included.

## Targeted red and green

`python .scratch/credential-security-closure/06-review-regression.py red` ran against original helper SHA256 `c318b12564bd4143edfc6bd9d018394deeb8dfe587c88e37cb82f11ff6edfc08`. All five public cases failed as intended; raw red stdout/stderr and JSON remain unchanged. Unset status raises `VariableIsUndefined`; seeded status 19 causes the actual verify script to reject the exact correct version. Failure case catches child exit 41 but exposes the missing exit-state publication.

After the three-line helper change, the same producer with `green` passes all five cases in fresh Windows PowerShell `5.1.17763.316`: successful compiler with unset/stale status; failed child exit 41 published before throw; actual public verify script with unset/stale status. The controlled native fake compiler reads empty stdin, returns the exact pinned version, then deliberately exits 73 at `fmt`. Both verify cases observe that exit and expected throw. Original synthetic binary framed stdin (including NUL/CR/LF/0xff) remains byte-for-byte readable after every case. These are real pipe/process/public-script calls, not extracted private functions.

`python .scratch/credential-security-closure/06-review-check-wrappers.py` replays all four migrated wrappers in a unique apostrophe/space fixture path with newly built synthetic public credential-input children. Four success cases verify empty compiler stdin plus accepted native frame; four retired EnvFile cases reject before compiler/native execution. The Linux wrapper runs its synthetic ELF through local WSL. Its placeholder libraries are never linked. Original task 05 producer/log files are unchanged; this derived task 06 producer and logs have distinct identities.

## Commands and identities

The exact compiler is `D:/Program Files/zig/zig.exe`, `0.17.0-dev.315+5b647b792`; manifest `06-review-validation.json` records its bytes, source/producer identities, actual command arrays, zero build exits, probe artifacts, and all retained result/log/report hashes. Builds were four targeted `build-exe -OReleaseSafe` commands, including one `-target x86_64-linux-gnu`; no full tests were run here. An initial PowerShell unquoted `-femit-bin=...` invocation failed argument parsing before compilation, followed by the recorded quoted argument build; no test qualification is claimed from that failed invocation.

## Limits

The long verify wave is intentionally stopped at fake fmt: no real fmt/build/test suite, curl bootstrap, live acceptance binary or network executes. Wrapper replay validates process/input wiring using synthetic children, not live Venue behavior. Root owns independent follow-up review and final frozen full Debug/ReleaseSafe validation. No real credentials, `.env.local`, network, orders, target dump/swap/power-loss, production qualification, main merge or push are involved. This patch resolves the shared P2 only; task 06 remains open for root's final acceptance and cleanup.
