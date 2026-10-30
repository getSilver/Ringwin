"""End-to-end acceptance for OwnerSession authentication and the RiskWarning
confirmation flow backend. Fails closed on any mismatch."""

import hashlib
import hmac
import http.client
import json
import os
import shutil
import sys
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control_plane
import control_plane_web
import owner_session

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = bytes(range(32))
PASSPHRASE = "correct horse battery staple"


class Clock:
    def __init__(self, now: int):
        self.now = now

    def __call__(self) -> int:
        return self.now


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


def request(client: http.client.HTTPConnection, method: str, path: str,
            body: Optional[dict] = None, cookie: str = "", csrf: str = "") -> tuple[int, dict]:
    headers = {"Content-Type": "application/json"}
    if cookie:
        headers["Cookie"] = f"{control_plane_web.SESSION_COOKIE}={cookie}"
    if csrf:
        headers[control_plane_web.CSRF_HEADER] = csrf
    encoded = json.dumps(body or {}).encode()
    client.request(method, path, body=encoded if body is not None else None,
                   headers=headers)
    response = client.getresponse()
    payload = json.loads(response.read())
    return response.status, payload


def totp_now(secret: str, clock: Clock) -> str:
    return owner_session.totp_at(secret, clock.now)


def rfc_vector_phase() -> None:
    # RFC 6238 Appendix B: ASCII secret "12345678901234567890" at T=59s gives
    # the 8-digit value 94287082; our policy uses 6 digits, so the expected
    # code is its low six digits.
    base32_secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    expect(owner_session.hotp(base32_secret, 59 // owner_session.TOTP_STEP)
           == "287082", "RFC 6238 Appendix B test vector")


def build_app(workdir: str, clock: Clock):
    server = control_plane.CommandServer(KEY)
    app = control_plane_web.ControlPlaneApp(workdir, server, clock=clock)
    httpd = control_plane_web.serve(app)
    import threading
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return server, app, httpd


def main() -> None:
    rfc_vector_phase()
    print("rfc_vector_phase=ok")

    workdir = os.path.join(ROOT, ".scratch", "owner-session-acceptance")
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)

    clock = Clock(1_700_000_000)
    server, app, httpd = build_app(workdir, clock)
    port = httpd.server_address[1]
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=10)

    # Setup: weak rejected, strong accepted exactly once.
    status, _ = request(client, "POST", "/setup", {"passphrase": "short"})
    expect(status == 400, "weak passphrase must be rejected")
    status, body = request(client, "POST", "/setup", {"passphrase": PASSPHRASE})
    expect(status == 200 and body["totp_secret"], f"setup failed: {body}")
    status, _ = request(client, "POST", "/setup", {"passphrase": PASSPHRASE})
    expect(status == 409, "second setup must conflict")
    print("setup_phase=ok")

    # Login failures: five bad passphrases trip the per-address limiter.
    secret = body["totp_secret"]
    code = totp_now(secret, clock)
    for _ in range(owner_session.RATE_LIMIT_MAX_FAILURES):
        status, _ = request(client, "POST", "/login",
                            {"passphrase": "wrong passphrase entirely", "code": code})
        expect(status == 401, "wrong passphrase must be 401")
    status, _ = request(client, "POST", "/login",
                        {"passphrase": PASSPHRASE, "code": code})
    expect(status == 429, "sixth attempt must be rate limited")

    # Cooldown passes on the injected clock; wrong TOTP fails, right one logs in.
    clock.now += owner_session.RATE_LIMIT_COOLDOWN_SECONDS + 1
    status, _ = request(client, "POST", "/login",
                        {"passphrase": PASSPHRASE, "code": "000000"})
    expect(status == 401, "wrong TOTP must be 401")
    code = totp_now(secret, clock)
    status, body = request(client, "POST", "/login",
                           {"passphrase": PASSPHRASE, "code": code})
    expect(status == 200 and body["csrf_token"], f"login failed: {body}")
    old_cookie = body["session_token"]
    print("login_phase=ok")

    # Replayed TOTP code is rejected (consumed step), even with fresh cooldown.
    status, _ = request(client, "POST", "/login",
                        {"passphrase": PASSPHRASE, "code": code})
    expect(status == 401, "replayed TOTP must be rejected")
    clock.now += owner_session.RATE_LIMIT_COOLDOWN_SECONDS + 1
    next_code = owner_session.totp_at(secret, clock.now)
    status, body2 = request(client, "POST", "/login",
                            {"passphrase": PASSPHRASE, "code": next_code})
    expect(status == 200, "second login must succeed")
    cookie = body2["session_token"]
    csrf = body2["csrf_token"]
    # Single active session: the previous token is now invalid.
    status, _ = request(client, "GET", "/operator-records",
                        cookie=old_cookie, csrf="irrelevant")
    expect(status == 401, "old session must be revoked by new login")
    print("single_session_phase=ok")

    # Unauthenticated access is rejected outright.
    status, _ = request(client, "POST", "/command",
                        {"kind": "cancel_open_orders", "target_identity": 1,
                         "expected_version": 4, "expires_at": clock.now + 60,
                         "command_identity": 50})
    expect(status == 401, "unauthenticated command must be 401")

    # CSRF baseline: valid cookie without header fails closed.
    base_command = {
        "kind": "cancel_open_orders",
        "target_identity": 1,
        "expected_version": 4,
        "expires_at": clock.now + 600,
        "command_identity": 51,
    }
    status, _ = request(client, "POST", "/command", base_command, cookie=cookie)
    expect(status == 403, "missing CSRF header must be 403")
    print("csrf_phase=ok")

    def authed(method: str, path: str, body=None):
        return request(client, method, path, body, cookie=cookie, csrf=csrf)

    # High-risk command without a confirmed warning is refused.
    enable = dict(base_command, kind="enable_trading", command_identity=52)
    status, _ = authed("POST", "/command", enable)
    expect(status == 403, "high-risk command without warning must be 403")

    # Low-risk kinds never take warnings.
    status, _ = authed("POST", "/risk-warning", base_command)
    expect(status == 400, "low-risk warning request must be 400")

    # Warning flow for enable_trading: payload mismatch refuses; match queues.
    status, warning = authed("POST", "/risk-warning",
                             dict(enable, expected_version=enable["expected_version"]))
    expect(status == 200 and warning["warning_identity"],
           f"warning issue failed: {warning}")
    tampered = dict(enable, risk_warning_acknowledged=True,
                    risk_warning_identity=int(warning["warning_identity"]),
                    expected_version=99)
    status, _ = authed("POST", "/command", tampered)
    expect(status == 403, "payload mismatch against warning must be 403")

    status, warning = authed("POST", "/risk-warning", enable)
    signed_enable = dict(enable,
                         risk_warning_acknowledged=True,
                         risk_warning_identity=int(warning["warning_identity"]))
    status, body = authed("POST", "/command", signed_enable)
    expect(status == 200, f"confirmed high-risk command failed: {body}")

    # Low-risk command goes straight through.
    status, body = authed("POST", "/command", base_command)
    expect(status == 200, f"low-risk command failed: {body}")

    # The channel queue holds two validly signed envelopes.
    expect(len(server._pending) == 2,  # noqa: SLF001
           f"expected two queued envelopes, got {len(server._pending)}")
    for framed in server._pending:  # noqa: SLF001
        envelope = framed[4:]
        expect(envelope[0] == control_plane.ENVELOPE_VERSION, "envelope version")
        mac = envelope[1:33]
        message = b"".join([envelope[:1], envelope[33:]])
        expected_mac = hmac.new(KEY, message, hashlib.sha256).digest()
        expect(hmac.compare_digest(mac, expected_mac), "envelope MAC must verify")

    # Operator records captured both operations with operator attribution.
    status, body = authed("GET", "/operator-records")
    expect(status == 200 and len(body["records"]) == 2,
           f"expected two operator records: {body}")
    kinds = {record["kind"] for record in body["records"]}
    expect(kinds == {"enable_trading", "cancel_open_orders"},
           f"unexpected record kinds: {kinds}")
    expect(all(record["operator"] == "SystemOwner" for record in body["records"]),
           "records must attribute SystemOwner")
    print("risk_warning_phase=ok")

    # Session expiry on the injected clock closes everything again.
    clock.now += owner_session.SESSION_TTL_SECONDS + 1
    status, _ = authed("GET", "/operator-records")
    expect(status == 401, "expired session must be 401")
    print("expiry_phase=ok")

    httpd.shutdown()
    httpd.server_close()
    print("owner_session_acceptance=passed")


if __name__ == "__main__":
    main()
