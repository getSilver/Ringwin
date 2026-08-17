# Security Policy

## Supported Versions

Ringwin is currently under active development and is considered experimental software.

Security fixes are generally applied to the latest version of the `main` branch. Older commits, releases, or forks may not receive security updates.

| Version                  | Supported |
| ------------------------ | --------- |
| `main`                   | Yes       |
| Older versions / commits | No        |

## Reporting a Vulnerability

Please **do not open a public GitHub issue** for suspected security vulnerabilities.

If you believe you have found a security vulnerability in Ringwin, please report it privately to the project maintainer through GitHub's private vulnerability reporting feature, if available.

When submitting a report, please include as much of the following information as possible:

* A clear description of the vulnerability
* The affected component or code path
* Steps required to reproduce the issue
* A proof of concept, if applicable
* The potential security or correctness impact
* Any suggested mitigation or fix
* Relevant environment information, such as Zig version, operating system, or exchange adapter

Reports involving uncertain findings are also welcome. Trading systems often contain edge cases where correctness, state integrity, and security overlap.

## Security-Sensitive Areas

Ringwin processes external market and exchange data while maintaining state related to orders, positions, balances, accounting, and profit and loss.

Security review is therefore particularly important in areas including:

* Exchange API and WebSocket integrations
* Authentication and credential handling
* Untrusted external input parsing and validation
* Order creation, modification, cancellation, and reconciliation
* Risk-management boundaries
* Position, balance, and PnL accounting
* State-machine transitions
* Integer overflow, underflow, and numeric correctness
* Persistence and event logging
* Deterministic replay and state recovery
* Concurrency and synchronization
* Resource exhaustion and denial-of-service conditions
* Fault isolation between trading components
* Authorization or privilege boundaries introduced by future services or APIs

A bug does not need to allow traditional remote code execution to be considered security relevant. Issues that could cause unauthorized orders, incorrect balances, corrupted state, bypassed risk controls, inconsistent replay, or unsafe recovery behavior are considered important.

## Credentials and Secrets

API keys, exchange credentials, private keys, access tokens, and other secrets must never be committed to the repository.

Examples, tests, and documentation should use dummy credentials or environment variables.

If a real credential is accidentally committed, it should be considered compromised and revoked or rotated immediately, even if the commit is later removed from Git history.

## Scope

Ringwin is currently intended for development, experimentation, testing, and educational use.

It is **not currently intended for production trading with real funds**.

Nevertheless, security reports affecting realistic deployment scenarios are welcome, particularly when they expose weaknesses in architectural assumptions that may become important as the project matures.

## Responsible Disclosure

Please allow reasonable time to investigate and address a reported vulnerability before publicly disclosing technical details.

The maintainer may coordinate with the reporter regarding:

1. Reproduction and validation of the issue
2. Assessment of severity and affected components
3. Development of a fix
4. Addition of regression tests
5. Release or disclosure timing

Once a vulnerability has been resolved, public disclosure may include appropriate credit to the reporter unless anonymity is requested.

## Automated and AI-Assisted Security Research

Automated analysis, fuzzing, static analysis, property-based testing, and AI-assisted security review are welcome when performed responsibly.

Please avoid testing that could:

* Target real exchange accounts without authorization
* Send unintended live orders
* Consume excessive third-party API resources
* Disrupt services operated by others
* Expose credentials or private user data

Security tooling should preferably operate against local tests, mocks, recorded data, exchange demo environments, or other explicitly authorized systems.

## Security Design Goals

Ringwin aims to make security and correctness properties explicit and testable. Important design goals include:

* Deterministic and reproducible state transitions
* Strict validation of external inputs
* Precise financial calculations
* Clear trust and failure boundaries
* Fail-safe risk controls
* Recoverable and auditable state
* Regression tests for confirmed security findings

These goals are ongoing engineering objectives rather than guarantees.

## Disclaimer

Ringwin is experimental open-source software provided without warranty.

Users are responsible for evaluating the software, its security properties, and its suitability for their own use cases.
