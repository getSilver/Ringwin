"""Control-plane web backend: OwnerSession login, RiskWarning confirmation
flow for high-risk ControlCommands, and OperatorRecord persistence.

Security baseline (standard library only):
  - binds 127.0.0.1 only;
  - session cookie is HttpOnly + SameSite=Strict;
  - mutating endpoints additionally require the per-session CSRF token header;
  - login attempts are rate limited per source address.
"""

import hashlib
import hmac
import json
import os
import secrets
import struct
import threading
import time
from http import cookies as http_cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import control_plane
import owner_session
import release_lifecycle

SESSION_COOKIE = "owner_session"
CSRF_HEADER = "X-Owner-CSRF"

# Commands that revoke or grant authority require a prior RiskWarning ack;
# mirrors CONTEXT.md's high-risk operator list within the first-version set.
HIGH_RISK_KINDS = {
    "enable_trading",
    "de_risk",
    "stop_keep_positions",
    "resolve_latch",
    "kill_switch",
    "deploy_release",
    "forward_rollback",
    "credential_activate",
    "credential_revoke",
    "failover",
}

WARNING_TTL_SECONDS = 300

CONSEQUENCE_TEXT = {
    "enable_trading": "授权目标分片进入 Trading：允许策略提交新增风险的订单。",
    "trading_pause": "暂停目标分片交易并撤销全部挂单；不自动平仓。",
    "cancel_open_orders": "撤销目标分片当前全部未完成订单。",
    "stop_keep_positions": "停止目标分片并保留现有仓位；风险不会消失。",
    "de_risk": "以 Reduce-only 订单把目标分片降至目标敞口；完成对账前保持 Draining。",
    "resolve_latch": "解除一个已锁存的安全栅栏原因；解除后仍需显式 EnableTrading。",
    "kill_switch": "立即禁止目标分片新增风险并撤销全部挂单；不自动平仓，需人工解除。",
    "deploy_release": "验证并激活指定签名 ReleaseArtifact，目标范围会经历排空和版本切换。",
    "forward_rollback": "以新的正向发布切换到指定旧代码；不回滚订单、成交、持仓或账本。",
    "credential_activate": "激活指定凭证版本；旧凭证按生命周期策略退出。",
    "credential_revoke": "吊销指定凭证版本；相关交易权限必须先安全关闭。",
    "failover": "建立节点隔离并把指定故障域切换到已准入候选节点。",
}


class RiskWarningRegistry:
    """Single-use warning identities bound to an exact command payload."""

    def __init__(self):
        self._warnings: dict[int, dict] = {}

    def issue(self, command: dict, clock=lambda: int(time.time())) -> dict:
        identity = secrets.randbits(63) | (1 << 62)
        while identity in self._warnings:
            identity = secrets.randbits(63) | (1 << 62)
        command = dict(command)
        if command["kind"] == "kill_switch":
            # The kill latch identity is bound to the warning identity so
            # resolve_latch can reference it deterministically afterwards.
            command["referenced_latch_identity"] = identity
        record = {
            "warning_identity": identity,
            "command": command,
            "expires_at": clock() + WARNING_TTL_SECONDS,
        }
        self._warnings[identity] = record
        info = {
            "warning_identity": str(identity),
            "kind": command["kind"],
            "target_identity": str(command["target_identity"]),
            "consequence": CONSEQUENCE_TEXT.get(
                command["kind"], "该操作会改变目标范围的权威运行状态。"),
            "expires_at": record["expires_at"],
        }
        if command["kind"] == "kill_switch":
            info["referenced_latch_identity"] = str(identity)
        return info

    def consume(self, warning_identity: int, command: dict,
                clock=lambda: int(time.time())) -> bool:
        record = self._warnings.get(warning_identity)
        if record is None:
            return False
        del self._warnings[warning_identity]
        if clock() >= record["expires_at"]:
            return False
        return _commands_match(record["command"], command)


def _commands_match(a: dict, b: dict) -> bool:
    if a.get("kind") != b.get("kind"):
        return False
    integer_fields = ("target_identity", "expected_version", "target_position",
                      "referenced_latch_identity")
    if not all(int(a.get(field, 0) or 0) == int(b.get(field, 0) or 0)
               for field in integer_fields):
        return False
    exact_fields = ("target", "manifest_path", "expected_active", "details")
    return all(a.get(field) == b.get(field) for field in exact_fields)


class OperatorRecordStore:
    """Append-only JSON lines; one record per state-changing operation."""

    def __init__(self, directory: str):
        self.path = os.path.join(directory, "operator-records.jsonl")

    def append(self, entry: dict) -> None:
        release_lifecycle._ensure_safe_fields(entry)
        encoded = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode()
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "ab") as handle:
            handle.write(encoded + b"\n")
            handle.flush()
            os.fsync(handle.fileno())

    def read_all(self) -> list[dict]:
        if not os.path.exists(self.path):
            return []
        with open(self.path) as handle:
            return [json.loads(line) for line in handle if line.strip()]


class ProjectionProvider:
    """Read-only shard views via the Zig projection probe (single parser)."""

    def __init__(self, runtime_dir: str, probe_path: str):
        self.runtime_dir = runtime_dir
        self.probe_path = probe_path
        self._cache_key = None

    def views(self) -> list[dict]:
        import subprocess
        entries = []
        for name in sorted(os.listdir(self.runtime_dir)):
            if not name.startswith("shard-") or not name.endswith(".journal"):
                continue
            path = os.path.join(self.runtime_dir, name)
            stat = os.stat(path)
            entries.append((path, stat.st_mtime_ns, stat.st_size))
        views = []
        for path, mtime, size in entries:
            key = (path, mtime, size)
            if key == self._cache_key and views == [] and False:
                continue  # per-file caching kept simple: recompute each call
            with open(path, "rb") as handle:
                hex_text = handle.read().hex()
            hex_file = path + ".hex"
            with open(hex_file, "w", newline="\n") as handle:
                handle.write(hex_text)
            result = subprocess.run(
                [self.probe_path, "project", hex_file],
                capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                views.append({"target_identity": name,
                              "degraded": True, "reason": "projection_probe_failed"})
                continue
            view = json.loads(result.stdout.strip())
            view["source"] = os.path.basename(path)
            views.append(view)
        return views


class ControlPlaneApp:
    """Request routing and policy; transport-independent for acceptance."""

    def __init__(self, directory: str, server: control_plane.CommandServer,
                 clock=lambda: int(time.time()),
                 projection_provider=None, ui_path=None, release_manager=None,
                 lifecycle_outbox=None):
        self.directory = directory
        self.clock = clock
        self.passphrases = owner_session.PassphraseStore(directory)
        self.totp = owner_session.TotpStore(directory)
        self.sessions = owner_session.SessionManager(directory)
        self.rate_limiter = owner_session.RateLimiter()
        self.warnings = RiskWarningRegistry()
        self.records = OperatorRecordStore(directory)
        self.command_server = server
        self.projection_provider = projection_provider
        self.ui_path = ui_path
        self.csrf_by_token_hash: dict[str, str] = {}
        self.release_manager = release_manager
        self.lifecycle_outbox = lifecycle_outbox
        self._command_results: dict[int, tuple[str, dict]] = {}
        self._lifecycle_results: dict[int, tuple[str, dict]] = {}
        for record in self.records.read_all():
            if record.get("command_identity") is not None:
                identity = _parse_u128(record["command_identity"])
                if identity is not None and record.get("command_fingerprint"):
                    self._command_results[identity] = (
                        record["command_fingerprint"],
                        {"ok": True, "queued": record["kind"]})
                if record.get("lifecycle_fingerprint"):
                    self._lifecycle_results[identity] = (
                        record["lifecycle_fingerprint"],
                        {"ok": True, "kind": record["kind"],
                         "result": record.get("lifecycle_result", {})})
        self._command_lock = threading.Lock()
        self._lifecycle_lock = threading.Lock()

    # -- authentication ---------------------------------------------------

    def setup(self, passphrase: str) -> tuple[int, dict]:
        try:
            self.passphrases.set(passphrase)
        except ValueError as error:
            return 400, {"ok": False, "error": str(error)}
        except PermissionError:
            return 409, {"ok": False, "error": "already initialized"}
        secret = None
        if not os.path.exists(os.path.join(self.directory, "totp.secret")):
            secret = self.totp.initialize()
        return 200, {"ok": True, "totp_secret": secret}

    def initialize_totp(self) -> tuple[int, dict]:
        secret = self.totp.read_secret()
        return 200, {"ok": True, "totp_secret": secret}

    def login(self, passphrase: str, code: str, client_identity: str) -> tuple[int, dict]:
        if not self.rate_limiter.check(client_identity, self.clock):
            return 429, {"ok": False, "error": "rate limited"}
        if not self.passphrases.verify(passphrase, self.clock) \
                or not self.totp.verify(code, self.clock):
            self.rate_limiter.record_failure(client_identity, self.clock)
            return 401, {"ok": False, "error": "invalid credentials"}
        self.rate_limiter.record_success(client_identity)
        token = self.sessions.issue(self.clock)
        csrf = secrets.token_urlsafe(32)
        self.csrf_by_token_hash[hashlib.sha256(token.encode()).hexdigest()] = csrf
        return 200, {"ok": True, "session_token": token, "csrf_token": csrf}

    def authorize(self, headers: dict) -> tuple[int, dict]:
        clock = self.clock
        raw_cookie = headers.get("Cookie", "")
        token = ""
        try:
            jar = http_cookies.SimpleCookie(raw_cookie)
            if SESSION_COOKIE in jar:
                token = jar[SESSION_COOKIE].value
        except http_cookies.CookieError:
            pass
        if not token or not self.sessions.validate(token, clock):
            return 401, {"ok": False, "error": "unauthenticated"}
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        expected_csrf = self.csrf_by_token_hash.get(token_hash)
        provided_csrf = headers.get(CSRF_HEADER, "")
        if not expected_csrf or not hmac.compare_digest(expected_csrf, provided_csrf):
            return 403, {"ok": False, "error": "csrf check failed"}
        self.sessions.renew(token, clock)
        return 200, {"ok": True, "token_hash": token_hash}

    def logout(self, headers: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        self.sessions.revoke()
        self.csrf_by_token_hash.pop(body["token_hash"], None)
        return 200, {"ok": True}

    # -- operations -------------------------------------------------------

    def risk_warning(self, headers: dict, command: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        kind = command.get("kind")
        if kind not in CONSEQUENCE_TEXT:
            return 400, {"ok": False, "error": "unknown command kind"}
        if kind not in HIGH_RISK_KINDS:
            return 400, {"ok": False, "error": f"{kind} is not high-risk"}
        return 200, self.warnings.issue(command, self.clock)

    def submit_command(self, headers: dict, command: dict) -> tuple[int, dict]:
        with self._command_lock:
            return self._submit_command(headers, command)

    def _submit_command(self, headers: dict, command: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        kind = command.get("kind")
        if kind not in CONSEQUENCE_TEXT:
            return 400, {"ok": False, "error": "unknown command kind"}
        command_identity = _parse_u128(command.get("command_identity")) \
            if command.get("command_identity") is not None else None
        if command.get("command_identity") is not None and command_identity is None:
            return 400, {"ok": False, "error": "invalid command identity"}
        if command_identity is None:
            command["command_identity"] = secrets.randbits(62) | 1
            command_identity = command["command_identity"]
        if "expires_at" not in command:
            command["expires_at"] = self.clock() + 300
        fingerprint = json.dumps(command, sort_keys=True, separators=(",", ":"))
        if command_identity is not None and command_identity in self._command_results:
            previous, response = self._command_results[command_identity]
            if previous != fingerprint:
                return 409, {"ok": False, "error": "command identity conflict"}
            return 200, response
        acknowledged = bool(command.get("risk_warning_acknowledged"))
        warning_identity_raw = command.get("risk_warning_identity")
        if kind in HIGH_RISK_KINDS:
            if not acknowledged or not warning_identity_raw:
                return 403, {"ok": False,
                             "error": "high-risk command requires a confirmed RiskWarning"}
            warning_identity = _parse_u128(warning_identity_raw)
            if warning_identity is None or not self.warnings.consume(
                    warning_identity, command, self.clock):
                return 403, {"ok": False,
                             "error": "risk warning missing, expired, or payload mismatch"}
        else:
            if warning_identity_raw or acknowledged:
                return 400, {"ok": False,
                             "error": "low-risk commands carry no risk warning"}
        import sys as _sys
        print(f"[enqueue {id(self.command_server):x}] {command['kind']} -> pending will be {len(self.command_server._pending) + 1}",
              file=_sys.stderr, flush=True)
        self.command_server.enqueue(_normalized_command(command))
        self.records.append({
            "recorded_at": self.clock(),
            "kind": kind,
            "command_identity": str(command_identity),
            "command_fingerprint": fingerprint,
            "target_identity": str(command["target_identity"]),
            "expected_version": command.get("expected_version"),
            "risk_warning_identity": str(warning_identity_raw) if warning_identity_raw else None,
            "acknowledged": acknowledged,
            "operator": "SystemOwner",
        })
        response = {"ok": True, "queued": kind}
        self._command_results[command_identity] = (fingerprint, response)
        return 200, response

    def lifecycle(self, headers: dict, command: dict) -> tuple[int, dict]:
        with self._lifecycle_lock:
            return self._lifecycle(headers, command)

    def _lifecycle(self, headers: dict, command: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        if self.release_manager is None or self.lifecycle_outbox is None:
            return 503, {"ok": False, "error": "lifecycle backend unavailable"}
        kind = command.get("kind")
        supported = set(release_lifecycle.LIFECYCLE_KINDS) | {
            "deploy_release", "forward_rollback"}
        if kind not in supported:
            return 400, {"ok": False, "error": "unknown lifecycle command"}
        command_identity = _parse_u128(command.get("command_identity"))
        if command_identity is None:
            return 400, {"ok": False, "error": "lifecycle command identity is required"}
        fingerprint = json.dumps(command, sort_keys=True, separators=(",", ":"))
        previous = self._lifecycle_results.get(command_identity)
        if previous is not None:
            if previous[0] != fingerprint:
                return 409, {"ok": False, "error": "lifecycle identity conflict"}
            return 200, previous[1]
        acknowledged = bool(command.get("risk_warning_acknowledged"))
        warning_identity_raw = command.get("risk_warning_identity")
        if kind in HIGH_RISK_KINDS:
            if not acknowledged or not warning_identity_raw:
                return 403, {"ok": False,
                             "error": "high-risk lifecycle command requires RiskWarning"}
            warning_identity = _parse_u128(warning_identity_raw)
            if warning_identity is None or not self.warnings.consume(
                    warning_identity, command, self.clock):
                return 403, {"ok": False,
                             "error": "risk warning missing, expired, or payload mismatch"}
        elif warning_identity_raw or acknowledged:
            return 400, {"ok": False, "error": "lifecycle warning is not valid for this command"}
        try:
            if kind == "deploy_release":
                result = self.release_manager.deploy(
                    command_identity, command["manifest_path"], command.get("expected_active"))
            elif kind == "forward_rollback":
                result = self.release_manager.forward_rollback(
                    command_identity, command["manifest_path"], command.get("expected_active"))
            else:
                result = self.lifecycle_outbox.submit(
                    command_identity, kind, command.get("target", "global"),
                    command.get("details", {}))
        except (KeyError, ValueError, release_lifecycle.ReleaseError) as error:
            status = 409 if "identity conflict" in str(error) else 400
            return status, {"ok": False, "error": str(error)}
        response = {"ok": True, "kind": kind, "result": result}
        self._lifecycle_results[command_identity] = (fingerprint, response)
        self.records.append({
            "recorded_at": self.clock(),
            "kind": kind,
            "command_identity": str(command_identity),
            "lifecycle_fingerprint": fingerprint,
            "lifecycle_result": result,
            "target_identity": str(command.get("target_identity", command.get("target", "global"))),
            "result": result.get("status", "queued") if isinstance(result, dict) else "queued",
            "operator": "SystemOwner",
        })
        return 200, response

    def operator_records(self, headers: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        return 200, {"ok": True, "records": self.records.read_all()}

    def projection(self, headers: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        if self.projection_provider is None:
            return 503, {"ok": False, "error": "projection unavailable"}
        try:
            views = self.projection_provider.views()
        except (OSError, subprocess_error()) as error:
            return 503, {"ok": False, "error": f"projection failed: {error}"}
        return 200, {"ok": True, "shards": views}

    def releases(self, headers: dict) -> tuple[int, dict]:
        status, body = self.authorize(headers)
        if status != 200:
            return status, body
        if self.release_manager is None:
            return 503, {"ok": False, "error": "release backend unavailable"}
        root = self.release_manager.release_root
        manifests = [os.path.join(root, name) for name in sorted(os.listdir(root))
                     if name.endswith(".json")]
        return 200, {"ok": True,
                     "active_artifact": self.release_manager.active_artifact(),
                     "manifests": manifests}

    def ui_page(self) -> tuple[int, bytes, str]:
        if self.ui_path is None or not os.path.exists(self.ui_path):
            return 404, b"ui not deployed", "text/plain"
        with open(self.ui_path, "rb") as handle:
            html = handle.read()
        return 200, html, "text/html; charset=utf-8"


def subprocess_error():
    import subprocess
    return subprocess.SubprocessError


from typing import Optional


def _parse_u128(value) -> Optional[int]:
    try:
        parsed = int(str(value), 0)
    except (TypeError, ValueError):
        return None
    if parsed <= 0 or parsed >= 1 << 128:
        return None
    return parsed


def _to_int(value) -> int:
    if isinstance(value, int):
        return value
    return int(str(value), 0)


def _normalized_command(command: dict) -> dict:
    normalized = {
        "command_identity": _to_int(command["command_identity"]),
        "target_identity": _to_int(command["target_identity"]),
        "expected_version": int(command["expected_version"]),
        "expires_at": int(command["expires_at"]),
        "kind": command["kind"],
    }
    if command.get("target_position"):
        normalized["target_position"] = int(command["target_position"])
    if command.get("referenced_latch_identity"):
        normalized["referenced_latch_identity"] = _to_int(command["referenced_latch_identity"])
    if command.get("risk_warning_acknowledged"):
        normalized["risk_warning_acknowledged"] = True
    if command.get("risk_warning_identity"):
        normalized["risk_warning_identity"] = _to_int(command["risk_warning_identity"])
    return normalized


def make_handler(app: ControlPlaneApp):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # silence default stderr noise
            pass

        def _json(self, status: int, body: dict, extra_headers=None) -> None:
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            for key, value in (extra_headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(encoded)

        def _read_body(self) -> dict:
            length = int(self.headers.get("Content-Length", "0"))
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            return json.loads(raw)

        def _post(self, handler_fn):
            try:
                body = self._read_body()
                status, response = handler_fn(body)
            except (ValueError, KeyError, json.JSONDecodeError) as error:
                status, response = 400, {"ok": False, "error": str(error)}
            extra = {}
            if (getattr(handler_fn, "__name__", "") == "_handle_login"
                    and response.get("ok")):
                extra["Set-Cookie"] = (
                    f"{SESSION_COOKIE}={response['session_token']}; "
                    "Path=/; HttpOnly; Secure; SameSite=Strict")
            self._json(status, response, extra)

        def _get(self, handler_fn):
            try:
                status, response = handler_fn(self.headers)
            except (ValueError, KeyError) as error:
                status, response = 400, {"ok": False, "error": str(error)}
            self._json(status, response)

        def do_POST(self):
            routes = {
                "/setup": lambda: self._post(lambda body: app.setup(body.get("passphrase", ""))),
                "/login": lambda: self._post(self._handle_login),
                "/logout": lambda: self._post(lambda body: app.logout(dict(self.headers))),
                "/risk-warning": lambda: self._post(
                    lambda body: app.risk_warning(dict(self.headers), body)),
                "/command": lambda: self._post(
                    lambda body: app.submit_command(dict(self.headers), body)),
                "/lifecycle": lambda: self._post(
                    lambda body: app.lifecycle(dict(self.headers), body)),
            }
            handler = routes.get(self.path)
            if handler is None:
                self._json(404, {"ok": False, "error": "not found"})
                return
            handler()

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                status, body, content_type = app.ui_page()
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            routes = {
                "/operator-records": lambda: self._get(app.operator_records),
                "/api/projection": lambda: self._get(app.projection),
                "/api/releases": lambda: self._get(app.releases),
                "/totp-secret": lambda: self._get(lambda headers: app.initialize_totp()),
            }
            handler = routes.get(self.path)
            if handler is None:
                self._json(404, {"ok": False, "error": "not found"})
                return
            handler()

        def _handle_login(self, body):
            status, response = app.login(
                body.get("passphrase", ""), body.get("code", ""),
                self.client_address[0])
            return status, response

    return Handler


def serve(app: ControlPlaneApp) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0),
                                 make_handler(app))
    server.daemon_threads = True
    return server

