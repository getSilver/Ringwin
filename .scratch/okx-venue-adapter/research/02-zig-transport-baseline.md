# Zig 0.17 OKX transport baseline

Research date: 2026-08-11

Pinned compiler: `0.17.0-dev.315+5b647b792`

Decision target: Windows Demo Trading acceptance plus `x86_64-linux-gnu` cross-build

## Decision

Use one direct third-party transport dependency: **libcurl 8.21.0**, pinned to the
signed upstream tag/commit `curl-8_21_0` / `68720b4837284335b2d63cb358f8f6ce65f5bc55`.
Use libcurl for both OKX REST over HTTPS and public/private WebSocket over WSS.
Keep request signing and JSON in the pinned Zig standard library
(`HmacSha256`, standard Base64, and `std.json`). Do not introduce a second Zig
HTTP client, a second TLS stack in the same target, or an in-house WebSocket
handshake/framer.
[libcurl 8.21.0 tag](https://github.com/curl/curl/releases/tag/curl-8_21_0),
[pinned Zig HMAC-SHA256](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/crypto/hmac.zig#L7-L13),
[pinned Zig Base64](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/base64.zig#L37-L43),
[pinned Zig JSON](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/json.zig)

The per-target libcurl artifact is part of the dependency, including its TLS
backend:

- Windows: libcurl 8.21.0 with Schannel, WebSocket and proxy support enabled.
  Schannel uses the Windows root certificate store by default.
- `x86_64-linux-gnu`: libcurl 8.21.0 with the distribution/qualified OpenSSL
  backend and CA bundle. The cross-build must consume a target-architecture
  libcurl artifact; it must not accidentally link the Windows host library.

The current machine's `C:\Windows\System32\curl.exe` reports libcurl 7.55.1 and
does not list `ws`/`wss`, so the OS curl is explicitly **not** an acceptable
dependency. At process start, fail closed unless runtime version/protocol
introspection proves libcurl `8.21.0`, HTTPS, WS and WSS and the expected TLS
backend.

## Why the pinned Zig standard library is not the complete transport

The pinned `std.http.Client` is useful evidence but not a sufficient baseline:

- It includes TLS, a system-rescanned CA bundle, connection pooling, HTTP and
  HTTPS proxy fields, proxy environment parsing, and HTTP CONNECT tunneling.
  [Pinned Client fields](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/http/Client.zig#L1-L62),
  [proxy initialization](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/http/Client.zig#L1291-L1368),
  [CONNECT tunneling](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/http/Client.zig#L1517-L1621)
- `ConnectTcpOptions` exposes `timeout: Io.Timeout`, but the pinned
  `connectTcpOptions` calls `host.connect` without using that field. Therefore
  this exact compiler source does not prove a bounded DNS/TCP/TLS connection
  phase. [Pinned connection implementation](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/http/Client.zig#L1429-L1470)
- The HTTP client has no client WebSocket handshake/framing API. The WebSocket
  implementation present in this standard library is attached to
  `std.http.Server`, not `std.http.Client`.
  [Pinned HTTP server WebSocket](https://github.com/ziglang/zig/blob/5b647b792c680a32c44823a050672537424c95c1/lib/std/http/Server.zig#L522-L800)

Adding a home-grown RFC 6455 client on top of `std.http.Client` would violate
the explicit “do not build TLS/WebSocket ourselves” constraint and would still
leave the pinned timeout hole.

The Zig-native candidate `karlseguin/websocket.zig` was also rejected for this
wave. Its upstream client does use `std.crypto.tls`, validates the WebSocket
handshake, and supports frames/read-write timeouts, but the current source has
no proxy path and explicitly says that connect/TLS-handshake timeout is not
enforced on Windows. Its README also describes the 0.16 line as experimental,
not a release qualified for this pinned 0.17 dev compiler.
[client timeout limitation](https://github.com/karlseguin/websocket.zig/blob/b70e733bc0d0ba0a98ff5fe5ef64d3017c85f369/src/client/client.zig#L239-L261),
[upstream version statement](https://github.com/karlseguin/websocket.zig/blob/b70e733bc0d0ba0a98ff5fe5ef64d3017c85f369/README.md#zig-version)

## Why libcurl 8.21.0 fits

### HTTPS, WSS and proxy

libcurl's WebSocket API accepts `ws://` and `wss://`, performs the HTTP Upgrade,
parses frames, handles ping/pong, and offers callback and connect-only models.
Full-duplex callback sending is available from 8.16.0, so 8.21.0 contains the
needed interface. libcurl deliberately does not negotiate WebSocket
extensions, which is acceptable for the current OKX contract but must remain a
recorded capability limit. Incoming frames may arrive in chunks and therefore
must be reassembled using the supplied frame metadata under a configured
message-size bound.
[WebSocket interface](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/libcurl-ws.md)

`CURLOPT_PROXY` supports explicit proxy schemes and credentials, HTTP
tunneling, standard proxy environment variables and `NO_PROXY`. Production
code should prefer explicit configuration and redact credentials; environment
fallback is an operator convenience, not authoritative configuration.
[proxy contract](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_PROXY.md)

### Certificate verification

Keep both peer-chain and hostname verification enabled. libcurl documents
`CURLOPT_SSL_VERIFYPEER=1` and `CURLOPT_SSL_VERIFYHOST=2` as the strict checks;
disabling either is forbidden. A Schannel build uses the Windows root store by
default, while the Linux artifact must carry or point to its qualified CA
bundle.
[peer verification](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_SSL_VERIFYPEER.md),
[hostname verification](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_SSL_VERIFYHOST.md),
[CA selection and Schannel behavior](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_CAINFO.md)

### Timeout and cancellation

Each REST handle must set a connect deadline and an overall request deadline.
`CURLOPT_CONNECTTIMEOUT_MS` covers DNS and all connection handshakes;
`CURLOPT_TIMEOUT_MS` caps the whole transfer. Long-lived WebSockets use the
connect deadline plus application heartbeat/read-stall deadlines rather than
an overall transfer timeout.
[connect timeout](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_CONNECTTIMEOUT_MS.md),
[overall timeout](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/opts/CURLOPT_TIMEOUT_MS.md)

One transport owner thread owns every easy/multi handle; libcurl explicitly
forbids sharing the same handle concurrently across threads. Other threads
enqueue commands and call `curl_multi_wakeup`. The owner drains the queue and
uses `curl_multi_remove_handle` to halt a transfer. This supplies a bounded,
auditable cancellation path without callbacks entering TradingShard.
[thread rule](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/libcurl-thread.md),
[wakeup](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/curl_multi_wakeup.md),
[remove/stop semantics](https://github.com/curl/curl/blob/curl-8_21_0/docs/libcurl/curl_multi_remove_handle.md)

### Recovery ownership

libcurl detects transport completion/failure; it does not own trading recovery.
The adapter state machine owns reconnect backoff, public/private re-login and
resubscription, sequence-gap detection, REST snapshot/reconciliation, and the
transition of unresolved commands to `Unknown`. Automatic replay of trading
POST requests is forbidden. A REST request may be retried only under the
already-agreed idempotency/reconciliation rules.

## Build and acceptance contract

Pin the upstream source/tag plus artifact digest. Build only the required
HTTP/HTTPS/WS/WSS and proxy capabilities; do **not** use curl's `HTTP_ONLY`
option because upstream CMake makes that option disable WebSocket. Explicitly
disable unused protocols and optional HTTP/2, HTTP/3, LDAP, compression and
authentication dependencies unless a later OKX contract requires them.
Upstream CMake exposes shared/static builds, Schannel/OpenSSL selection and
WebSocket enablement (`CURL_DISABLE_WEBSOCKETS=OFF`).
[upstream CMake options](https://github.com/curl/curl/blob/curl-8_21_0/docs/INSTALL-CMAKE.md),
[WebSocket build switches](https://github.com/curl/curl/blob/curl-8_21_0/CMakeLists.txt#L507-L556)

Before the adapter can claim transport qualification, automated checks must
prove on Windows and for the Linux target artifact:

1. exact libcurl version, HTTPS/WS/WSS protocol list and expected TLS backend;
2. valid OKX certificate succeeds; unknown CA, hostname mismatch and disabled
   verification configuration fail closed;
3. direct and HTTP CONNECT proxy paths work without leaking proxy/API secrets;
4. DNS/connect/TLS, REST overall, WS heartbeat/read-stall and explicit cancel
   deadlines terminate within bounded grace;
5. fragmented/chunked WS messages, ping/pong/close and bounded message size;
6. reconnect never silently replays an order and always enters the agreed
   resubscribe/reconcile/`Unknown` path;
7. Windows native build and Zig `x86_64-linux-gnu` cross-link use their own
   target libcurl artifacts.

## Remaining qualification fog

- libcurl 8.21.0's public documentation says extensions are unsupported. In
  the cited source block, the RFC 6455 checks for `Sec-WebSocket-Accept`,
  extensions and subprotocols are stated as comments but no validation is
  performed before switching protocols. This is an inference from the upstream
  implementation: Demo endpoint acceptance must therefore be proven, and this
  baseline must not be promoted to production qualification without a focused
  handshake conformance review.
  [upstream handshake source](https://github.com/curl/curl/blob/curl-8_21_0/lib/ws.c#L1418-L1435)
- The exact Linux OpenSSL/CA artifact and reproducible cross-build recipe must
  be frozen with artifact hashes during the build-seam implementation. The
  decision here fixes the C ABI and libcurl version, not a future production
  Linux distribution image.
- Timeout constants, reconnect jitter/backoff and maximum WS message size are
  operating parameters to measure in Demo acceptance, not facts supplied by
  the transport library.
