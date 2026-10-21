<div align="center">

# Ringwin
[简体中文](README.zh.md)
**Ringwin is an experimental deterministic trading engine written in Zig.**

It is designed as both a practical trading-system prototype and an open-source reference for developers interested in applying Zig to complex, stateful, reliability-sensitive software.
</div>

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/getSilver/Ringwin)

Ringwin focuses on deterministic state transitions, fixed-point financial arithmetic, explicit risk and order-management boundaries, replayable event processing, and fault isolation.

The offline implementation now exercises a shared OKX, Binance, and Bybit VenueAdapter/MarketFeedAdapter seam for spot and isolated linear USDT contracts. Real Testnet and production-account qualification remain separate and are never inferred from offline evidence.

> [!WARNING]
> Ringwin is under active development and is **not currently intended for production trading or real-fund deployment**.

## Why Ringwin?

Many Zig examples focus on language features or relatively small programs.

Ringwin explores how Zig can be used in a larger real-world system involving:

* market data processing;
* strategy execution;
* risk management;
* order management;
* positions and balances;
* accounting, fees, and PnL;
* exchange integration;
* bounded in-memory event logging in the offline fixture;
* deterministic replay;
* process and shard fault isolation.

The broader goal is to provide an inspectable reference implementation for developers learning systems programming with Zig.

## Design Goals

Ringwin is built around a few core principles:

### Deterministic behavior

Authoritative trading state is updated through ordered events handled by the same core state machine.

The same event history should reproduce equivalent authoritative state during replay.

### Fixed-point arithmetic

Prices, quantities, balances, fees, margin, and PnL use fixed-point integer representations.

Floating-point values are not used for authoritative financial state transitions.

### Explicit authority boundaries

Strategies produce `OrderIntent` values.

Risk validation, OMS state, positions, balances, and accounting remain authoritative inside the Zig trading core.

Python strategies are supported through an isolated `StrategyHost`, but Python does not directly own authoritative trading state.

### Fail-safe behavior

When state cannot be established safely, Ringwin prefers to reject, stop, fence, or reconcile rather than silently continue with uncertain state.

## Architecture

A simplified execution path looks like this:

```text
Market / Exchange
       │
       ▼
  VenueAdapter
       │
       ▼
   Market Data
       │
       ▼
    Strategy
       │
       ▼
   OrderIntent
       │
       ▼
      Risk
       │
       ▼
      OMS
       │
       ▼
 OrderCommand
       │
       ▼
Exchange / Simulator
       │
       ▼
Execution Reports
       │
       ▼
Position / Accounting / PnL
       │
       ▼
     Journal
       │
       ▼
Deterministic Replay
```

The engine can run multiple isolated `TradingShard` instances, each with its own state, queues, journal, and failure boundary.

More detailed architecture and domain definitions are available in:

* [`GLOSSARY.md`](GLOSSARY.md)
* [`docs/trading-engine-architecture.html`](docs/trading-engine-architecture.html)

## Current Features

The current implementation includes:

* deterministic `TradingShard` state machines;
* native Zig strategies;
* isolated Python `StrategyHost` support;
* fixed-point risk calculations;
* order management;
* position and balance tracking;
* fees and PnL accounting;
* margin reservations;
* bounded in-memory journal encoding with integrity checks;
* CRC32C integrity checks;
* deterministic replay;
* duplicate-event handling;
* reconciliation of uncertain order state;
* multi-shard fault isolation;
* OKX Demo Trading integration.

## OKX Demo Trading

Ringwin includes an integration path for **OKX Demo Trading**.

The current implementation supports areas such as:

* market data;
* order placement;
* amendments;
* cancellations;
* execution reports;
* partial and full fills;
* REST reconciliation;
* reconnect handling;
* unknown order state.

The Demo integration is intended for testing and validation only.

Its live result is recorded as `DemoQualified` in the shared venue evidence
model. It is never promoted to `TestnetQualified` or production qualification;
those require the matching environment and venue-specific run evidence.

## Requirements

The current development environment uses:

* Zig `0.17.0-dev.315+5b647b792`
* Python `3.9+`

Windows and Linux are eligible for independent production qualification, with
`ReleaseSafe` as the default. This is a support-policy decision; the current code
still implements a Linux-only production contract. Windows production admission
and qualification remain pending. Windows Demo verification cannot grant
`production_qualified`. See [ADR 0010](docs/adr/0010-qualify-windows-and-linux-independently.md)
and [`.scratch/windows-process-chain-verification/map.md`](.scratch/windows-process-chain-verification/map.md).
The Linux production map remains [`.scratch/production-readiness/map.md`](.scratch/production-readiness/map.md).
The exact support matrix and schema gate live in [`src/runtime/production_contract.zig`](src/runtime/production_contract.zig).
See [source layout](docs/source-layout.md) for module ownership, the complete file migration map, and standalone Zig checks.

Check your Zig version:

```console
zig version
```

## Build and Test

Clone the repository:

```console
git clone https://github.com/getSilver/Ringwin.git
cd Ringwin
```

Use the unified build entrypoint:

```console
zig build
zig build test
zig build run -- --offline-fixture
zig build windows-durable
zig build windows-credential
zig build windows-chain
zig build windows-okx-offline
zig build windows-okx-readonly
```

`zig build windows-chain` includes the historical five-process
SimulatedVenue lifecycle and reports `historical_simulated_chain=passed` with
`windows_process_chain_verified=blocked`. Windows OKX evidence must separately pass
offline, read-only, and explicitly authorized Demo trading, plus role ownership,
durable recovery, and final account reconciliation, scoped to a source revision,
account, product, strategy, and configuration. `.env.local` supplies Demo
credentials only; it does not authorize orders or cleanup. Windows evidence
cannot qualify Linux production or Binance/Bybit Testnet.
The same command now emits a separate `windows_okx_offline=passed` line only after
the OKX fake-transport five-process path and disk replay pass. The historical
aggregate line remains blocked; qualification comes from the scoped OKX reports.
`windows-okx-offline` writes a source-bound JSON report in
`.scratch/windows-process-chain-verification/report-offline.json`; the read-only
step writes its own report after matching that source snapshot and the Demo
account fingerprint. Neither step places orders. A fresh, bounded SystemOwner
authorization is required before `zig build windows-okx-live
-Dwindows-demo-live-authorized=true`. The live step requires matching offline
and read-only reports and writes `report-demolive.json`; absent any mode or a
complete terminal and zero-exposure result, verification stays blocked or failed.

[Ticket 06 sealed evidence](.scratch/windows-process-chain-verification/report-demolive-2026-10-03-recovered.json)
qualifies execution revision `9939110d` for the authorized OKX Demo BTC-USDT spot
round trip. The original parser failure is preserved; durable recovery and
authoritative read-only queries supply the missing wire order IDs. Collector
identity is recorded separately. Later runtime changes do not inherit this online
qualification; `production_qualification=false`.

Run the full offline core wave:

```powershell
zig build core-wave
```

Linux production roles remain a separate Linux-only dispatcher (`--production-role`,
`--production-chain-test`, `--durable-store-test`, `--credential-store-test`).
Windows verification uses `--verify-role` / `--windows-chain-test` and never
replaces those flags. Cross-compiling the Linux source remains:

```console
zig test src/main.zig -target x86_64-linux-gnu -OReleaseSafe --test-no-exec
```

`--credential-store-test` exercises the Linux-only encrypted `CredentialStore`: Argon2id and
XChaCha20-Poly1305 authenticated metadata, separate observation/execution files, forward-only
credential lifecycle, protected-memory self-checks, fixed node/egress context, and a read-only
`Ready` admission. It never enables trading or prints credential bytes. Target-node secret scanning,
RLIMIT_MEMLOCK, crash-dump, and real production-account qualification remain separate evidence.

The systemd template and target are in [`deploy/systemd`](deploy/systemd):
each role uses a separate `ringwin-%i` user and runtime directory. Only the
execution-gateway drop-in allows Internet address families; the base unit is
Unix-domain-socket-only.

Run the explicit OKX Demo wave (read-only preparation by default):

```powershell
zig build demo-wave
```

Only run Demo order execution with SystemOwner authorization:

```powershell
zig build demo-wave -Ddemo-live
```

The offline core wave reports OKX Demo, Binance Testnet, and Bybit Testnet
contract evidence independently. Without an explicit live run, each real-run
qualification remains `not_run`; OKX Demo evidence is never promoted to
`TestnetQualified`.

The current schema versions are defined in [`src/runtime/production_contract.zig`](src/runtime/production_contract.zig).
Four-shard evidence is produced by `zig build run -- --four-shard-acceptance`.
Replay has no send capability. Windows verification cannot set `permitsProduction()`.

All build steps reject a Zig version other than `0.17.0-dev.315+5b647b792` before running tests. The existing PowerShell wave scripts remain available as their underlying acceptance implementation. Use Demo credentials only.

## Deterministic Replay

The offline fixture records authoritative events in a bounded in-memory journal.
`--durable-store-test` additionally exercises the same store interface with a
real Linux directory: three permission-domain streams, a synced manifest,
atomic snapshot publication, close/reopen recovery, and injected fail-closed
errors. Target-filesystem power-loss and performance qualification remain
separate from this WSL/offline evidence.

The journal can be used to:

* validate record integrity;
* detect corruption or sequence gaps;
* recover state;
* replay historical events;
* compare reconstructed authoritative state.

This makes deterministic behavior a testable property rather than only a design goal.

## Python StrategyHost

Python strategies run outside the authoritative Zig trading state.

Communication uses a Zig-owned, validated anonymous-pipe framing boundary
([ADR 0007](docs/adr/0007-use-validated-pipes-for-strategy-host-data.md)).
Python does not receive shared-memory handles, mapping sizes, or atomic cursors.

A Python strategy can produce an `OrderIntent`, but that intent must still pass through Zig-side validation, risk checks, and OMS processing.

This design keeps strategy flexibility separate from trading authority.

## Testing

Ringwin contains automated tests for important system invariants, including:

* deterministic replay;
* fixed-point financial calculations;
* duplicate execution handling;
* journal corruption detection;
* truncated journal recovery;
* order reconciliation;
* risk reservations;
* StrategyHost crash and stale-session handling;
* multi-shard fault isolation.

Performance measurements in the repository are development regression benchmarks only and should not be interpreted as production latency guarantees.

## Project Status

Ringwin is actively evolving. The current repair wave has completed tickets
01–12 and its offline acceptance baseline is reproducible with
`tools\verify-core-wave.ps1`.

The current repository demonstrates a functional end-to-end trading-engine prototype, but several areas remain outside production qualification, including:

* real-fund deployment;
* production exchange accounts;
* production Linux performance qualification;
* production secret management;
* production failover and deployment fencing.

The project deliberately distinguishes between **implemented behavior**, **development testing**, and **production qualification**.

The completed repair wave does not grant real Venue qualification: Binance and
Bybit Testnet runs remain `not_run`, OKX Demo remains `DemoQualified` only when
its explicit live run has produced sealed evidence, and production/Linux
qualification remains outside this baseline. Historical closure maps are
retained for audit and do not override the current repair-wave evidence.

## Security

Trading systems process untrusted external data while maintaining sensitive state such as orders, positions, balances, and risk limits.

Security-sensitive areas include:

* exchange APIs;
* external input validation;
* credential handling;
* order state;
* risk controls;
* journal integrity;
* replay and recovery;
* numeric correctness;
* resource exhaustion;
* process isolation.

Please do not open public issues for suspected vulnerabilities.

See [`SECURITY.md`](SECURITY.md) for responsible disclosure instructions.

## Contributing

Contributions, bug reports, documentation improvements, testing, and design discussions are welcome.

Particular areas of interest include:

* Zig systems programming;
* deterministic architectures;
* testing and verification;
* exchange adapters;
* risk and OMS design;
* replay and recovery;
* security;
* portability.

For major architectural changes, opening a discussion before implementation is recommended.

## License

Ringwin is licensed under the [MIT License](LICENSE).

## Disclaimer

Ringwin is experimental open-source software intended for development, research, and educational purposes.

It is not financial advice and is not currently intended for production trading.

The software is provided **"AS IS"**, without warranty of any kind.
