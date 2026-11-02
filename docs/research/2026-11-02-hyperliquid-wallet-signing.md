# Hyperliquid wallet signing: ticket 03

Offline implementation on `feat/hyperliquid-adapter`; protocol source identity and
primary links remain in [the fixed SDK evidence](2026-11-02-hyperliquid-signing-history.md).
This document grants no wallet registration, live API access or trading authority.

## Credential and session boundary

`SecretMaterial` is a tagged union: `api_credentials` preserves the existing API
triple; `api_wallet` contains the 32-byte private scalar, its validated 20-byte
signer address, and an independently specified 20-byte funding account. No fake
API key or passphrase is needed. Private scalars must be in `[1,n-1]`; zero funding
addresses and mismatched derived signer addresses are rejected before signing.

The authenticated CRD4 outer envelope remains version 1. API triple payload v1
bytes remain unchanged, including the original synthetic audit fixture. Wallet
payload v2 is exactly `00 02 || key[32] || signer[20] || funding[20]` (74 bytes).
Zero was an invalid v1 API-key length, so existing readers reject the new payload;
the new reader accepts both and rejects unknown wallet versions or wrong lengths.
Canonical events, RawIngress, snapshots and the schema registry do not change.

Only execution credentials with trading permission, no withdrawal permission and
matching Testnet/production endpoints may stage wallet material. Staging uses
the existing encrypted store and clears caller material/password buffers.
Activation, retirement and revocation use the existing state machine. There is
no new CLI, control plane, wallet registration or execution admission. Existing
`admitExecution` still fails closed; observation admission grants no send ability.

`CredentialStore.signWallet` takes the existing restricted password stream,
revalidates active metadata, runtime account/environment/node/egress and expiry,
and consumes a short-lived `GatewayLease` under the existing stable writer lock.
Revocation uses that same lock. Private wallet material is not exposed by the
legacy read-only material callback. The public operation always checks session/fencing and consumes a durable request
before signing. Its digest callback receives only the reserved nonce, never a
lease or private key; binding/signing methods on the lease remain private.

`Signer.queryAccount()` always returns the explicitly bound funding address.
Master signing omits `vaultAddress`; subaccount signing puts that funding address
in the protocol's `vaultAddress` field. This does not enable vault trading. A
master agent's chain-side authorization is inferred by Hyperliquid, not encoded
as a master address in the L1 hash; local binding cannot prove remote approval.

The security-owned wallet session fingerprints signer, funding address, signing scope, real
account identity, environment, credential identity/version/generation/expiry,
node, egress and owner fencing token. Variable text is length-prefixed. Changes
produce a different session; stale request sessions and endpoint environments are
rejected. The security entry checks the existing `GatewayLeaseGuard`, account and owner token
before consuming a nonce and again before returning output. Actual elapsed awake
time across password input, KDF and signing advances the supplied monotonic
reference, so blocking unlock work cannot preserve an expired lease. Even cancel/reduce
signing conservatively requires a live primary lease in this first version.

## Nonce, crash and Unknown boundary

Staging a new wallet provisions an exclusive `<signer-hex>.signer-nonces` file.
SN01's 28-byte header binds the signer; each 36-byte record contains nonce,
ExchangeAccount, original durable dispatch identity and CRC32C. There are no keys,
signatures or signed request bodies in this ledger. A provisioning failure can
leave a staged credential; it cannot sign without a valid ledger. Reusing a
previous signer file is rejected; do not delete it to register a pruned wallet.

All cooperating users of one signer must use the same protected store and stable
writer lock. The lock covers unlock, scan, append, `File.sync` and signing. New
nonce is `max(now_ms, previous + 1)`, with checked overflow and a conservative
one-hour maximum future drift, inside the official one-day future window. Small
clock rollback retains monotonicity; excessive rollback fails closed. Local UTC
must still track the exchange clock; offline tests do not prove that condition.

The original command identity is durably consumed **before** generating a
signature. A signature error or crash may burn a nonce/request; it never makes
that request retryable. A repeated request stays rejected after reopening the
store, moving time forward or replacing the owner. Missing/corrupt/truncated
ledgers are never repaired/reset automatically. The bounded linear ledger refuses
new requests after 65,536 records; indexing/retention needs a separately proven
recovery design before qualifying sustained high-volume operation.

The durable dispatch identity is supplied by the existing Gateway. Caller must
preserve it through Unknown; changing identity or rotating a key is not retry
authorization. Cross-credential Unknown handling remains the Gateway's durable
dispatch responsibility. A signature is cryptographic output, not a trading
grant. Ticket 05 must keep the actual encoded request bytes identical to the hash
input, and ticket 07 must retain the existing DispatchProof/send checks, including
session changes, current fencing, revoked credentials and outstanding Unknowns.
This signing module contains no transport or auto-retry path.

Cross-machine copies of a store are not a coordinated nonce authority. Deployment
must preserve one durable ledger and enforce the existing external node fence;
independent hosts/stores sharing a signer are unsupported. Restoring an older
ledger is not a valid recovery procedure. Windows `File.sync` is functional
evidence, not directory/power-loss qualification.

## Cryptographic evidence and limitations

The exact ordered MessagePack action from the pinned official public hash test
is checked against `0fcbeda5...ac2908`. Fixed Testnet/Mainnet EIP-712 digests and
the subaccount plus expiry variant are independently reproduced using the pinned
SDK. The signing primitive uses RFC6979 HMAC-SHA256 with pinned Zig secp256k1
field/curve formulas, normalizes low-s and derives Ethereum recovery parity
from the public nonce point. The rare unsupported recovery-ID 2/3 case advances
RFC6979 state rather than returning an unrepresentable signature.
Keccak-256, network source `a`/`b`, Exchange/1 domain, chain 1337 and zero verifying
contract match the fixed upstream source. Administrative user-signed actions use
a different domain and are not exposed here.

Private scalar, nonce, RFC6979 state, HMAC pads, SHA-256 schedule and owned
working points live in one protected workspace. Existing hardened SHA-256 is
reused; no stdlib ECDSA Signer or HMAC frame copies raw key arrays. Key bytes are
borrowed for fixed-schedule scalar conversion and base multiplication, using
constant-time selection and existing field/curve formulas. Wallet decoding writes
directly into its protected destination instead of returning key material by value.

The independent Python oracle verifies all network/account/digest variants with
the pinned SDK. The public CredentialStore regression compares the resulting
RFC6979 signature hash with the SDK and recovers the expected public address.
Additional independent edge vectors cover scalar 1 with zero digest and scalar
`n-1` with maximum digest, including bits2octets reduction and low-s handling.
Tests use publicly known synthetic scalars and expired timestamps, never a real
wallet. No private key file or signature fixture is created.

Reproduce the oracle in a disposable environment with `msgpack==1.1.2`,
`eth-account==0.13.7`, `eth-keys==0.7.0`, `eth-utils==5.3.1`:

```text
python python/hyperliquid_signing_vectors.py <pinned-sdk-signing.py>
python tools/zig-entry.py test src/security/credential_store.zig
python tools/zig-entry.py test src/adapters/hyperliquid/hyperliquid_signer.zig -O ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

The oracle verifies the original SDK file SHA-256 before selecting its functions;
it prints only success and never prints keys or signatures. These Python packages
are offline oracle dependencies, not Ringwin runtime dependencies.

Owned credential, password, plaintext and signing workspace buffers use existing
protected memory and wipe-on-release. Windows native locking/protection and the
existing protection failure/erase tests are exercised, including direct workspace
erase observation on signing success and injected lock failure. By-value field
and curve arithmetic still creates transient scalar/point values; this change
**does not prove protected/zeroized arithmetic stack or register temporaries**.
Linux target behavior,
dump resistance for those temporaries, power-loss persistence, real external
node fencing, remote agent authorization and Testnet trading remain unqualified.
Do not treat offline completion as secret-memory or production qualification.

## Final offline evidence

Debug public credential/signing regressions passed 56/56; final ReleaseSafe
regressions including the additional edge case passed 57/57. Direct execution of
the complete ReleaseSafe test binary passed 834/834, exit 0. That full binary was
compiled before the last test-only edge addition; production implementation was
unchanged, and the latest targeted run covers the new case. The build-listener
log contains a `failed command` diagnostic despite its wrapper returning 0; the
explicit complete-binary output is the full-suite evidence. Artifact identity,
logs and review disposition are in [ticket 03](../../.scratch/hyperliquid-adapter/issues/03-api-wallet-signing.md).
