[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)]()

[简体中文](README.zh.md)

# Ringwin

**Ringwin is an experimental deterministic trading engine written in Zig.**

It is designed as both a practical trading-system prototype and an open-source reference for developers interested in applying Zig to complex, stateful, reliability-sensitive software.

Ringwin focuses on deterministic state transitions, fixed-point financial arithmetic, explicit risk and order-management boundaries, replayable event processing, and fault isolation.

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
* durable event logging;
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

* [`CONTEXT.md`](CONTEXT.md)
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
* durable event journals;
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

It does **not** imply production account support or production trading qualification.

## Requirements

The current development environment uses:

* Zig `0.17.0-dev.315+5b647b792`
* Python `3.9+`

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

Run the main test suite:

```console
zig test src/main.zig -O ReleaseSafe
```

Run the deterministic acceptance fixture:

```console
zig run src/main.zig -O ReleaseSafe
```

Run the Python StrategyHost acceptance suite:

```console
python python/verify_strategy_host.py
```

For OKX Demo acceptance on Windows:

```powershell
tools\verify-okx-demo-wave.ps1
```

Explicit Demo order execution requires:

```powershell
tools\verify-okx-demo-wave.ps1 -DemoLive
```

Use Demo credentials only.

## Deterministic Replay

Ringwin records authoritative events in a durable journal.

The journal can be used to:

* validate record integrity;
* detect corruption or sequence gaps;
* recover state;
* replay historical events;
* compare reconstructed authoritative state.

This makes deterministic behavior a testable property rather than only a design goal.

## Python StrategyHost

Python strategies run outside the authoritative Zig trading state.

Communication uses a Zig-owned shared-memory IPC boundary.

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

Ringwin is actively evolving.

The current repository demonstrates a functional end-to-end trading-engine prototype, but several areas remain outside production qualification, including:

* real-fund deployment;
* production exchange accounts;
* production Linux performance qualification;
* production secret management;
* production failover and deployment fencing.

The project deliberately distinguishes between **implemented behavior**, **development testing**, and **production qualification**.

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
