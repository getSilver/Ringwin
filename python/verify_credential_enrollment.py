"""Offline native enrollment -> authenticated HTTP import -> native unlock.

All inputs below are synthetic fixtures. No exchange request or real secret is
read. Python supplies fixture bytes only; production uses native hidden input.
"""
from __future__ import annotations

import base64
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

import control_plane
import control_plane_web
import credential_packages
import owner_session

ROOT = Path(__file__).resolve().parents[1]
PASSWORD = b"synthetic-enrollment-password\n"
KEY = bytes(range(32))


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    executable = ROOT / ".scratch/build/ringwin-credential.exe"
    if os.name != "nt":
        executable = executable.with_suffix("")
    executable.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tools/zig-entry.py"), "build-exe",
                    str(ROOT / "src/runtime/credential_enrollment.zig"), "-O", "ReleaseSafe",
                    "--stack", "67108864", f"-femit-bin={executable}"], check=True, cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="ringwin-credential-enrollment-") as temporary:
        root = Path(temporary)
        (root / "web").mkdir()
        clock = lambda: int(time.time())
        command_server = control_plane.CommandServer(KEY)
        app = control_plane_web.ControlPlaneApp(str(root / "web"), command_server, clock=clock)
        status, setup = app.setup("synthetic owner passphrase")
        expect(status == 200, "owner setup")
        status, login = app.login("synthetic owner passphrase",
                                  owner_session.totp_at(setup["totp_secret"], clock()), "127.0.0.1")
        expect(status == 200, "owner login")
        headers = {"Content-Type": "application/json",
                   "Cookie": "owner_session=" + login["session_token"],
                   "X-Owner-CSRF": login["csrf_token"]}
        server = control_plane_web.serve(app)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def request(method, path, body=None, request_headers=None):
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)
            try:
                connection.request(method, path, None if body is None else json.dumps(body),
                                   headers if request_headers is None else request_headers)
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        def native(operation, file, destination, fixture=PASSWORD, succeeds=True):
            result = subprocess.run([str(executable), operation, str(file), str(destination),
                                     "--restricted-input"], input=fixture, capture_output=True, timeout=90)
            expect((result.returncode == 0) == succeeds, f"native {operation}: {result.stderr.decode(errors='replace')}")
            for sensitive in (b"fixture-api-key", b"fixture-secret-key", PASSWORD.strip()):
                expect(sensitive not in result.stdout + result.stderr, "native output must not contain secrets")
            return json.loads(result.stdout) if succeeds else result

        try:
            expect(request("GET", "/api/credentials", request_headers={})[0] == 401, "GET requires login")
            expect(request("POST", "/api/credentials", {}, request_headers={})[0] == 401, "POST requires login")
            no_csrf = {key: value for key, value in headers.items() if key != "X-Owner-CSRF"}
            expect(request("POST", "/api/credentials", {}, no_csrf)[0] == 403, "POST requires CSRF")
            expect(request("POST", "/api/credentials", None)[0] == 400, "null cannot be an import")
            expect(request("POST", "/api/credentials", {"api_key": "fixture-api-key"})[0] == 400, "plaintext fields rejected")
            expect(request("POST", "/api/credentials", {"encrypted_package": "x" * 3000})[0] == 400, "oversized upload rejected")
            for venue in ("okx", "binance", "bybit", "hyperliquid"):
                config = {"venue": venue, "kind": "execution", "account": 7,
                          "environment": "testnet", "expires_at_unix": 4_000_000_000,
                          "credential_id": f"{venue}-fixture", "node_id": "node-7", "egress_ip": "203.0.113.7"}
                config_path = root / f"{venue}.json"
                config_path.write_text(json.dumps(config), encoding="utf-8")
                if venue == "hyperliquid":
                    fields = (b"0000000000000000000000000000000000000000000000000000000000000001\n"
                              b"7e5f4552091a69125d5dfcb7b8c2659029395bdf\n"
                              b"0202020202020202020202020202020202020202\n")
                else:
                    fields = b"fixture-api-key\nfixture-secret-key\n"
                    if venue == "okx":
                        fields += b"fixture-passphrase\n"
                producer = root / (venue + "-producer")
                enrolled = native("enroll", config_path, producer, fields + PASSWORD + PASSWORD)
                expect(enrolled["state"] == "staged" and not enrolled["trading_enabled"], "enrollment grants no trading")
                package_path, = producer.glob("*/execution.credential")
                encrypted = package_path.read_bytes()
                body = {"encrypted_package": base64.b64encode(encrypted).decode("ascii")}
                if venue == "okx":
                    append = app.records.append
                    def unavailable_record(_):
                        raise OSError("synthetic audit failure")
                    app.records.append = unavailable_record
                    try:
                        expect(request("POST", "/api/credentials", body)[0] == 503, "audit failure cannot report success")
                    finally:
                        app.records.append = append
                status, imported = request("POST", "/api/credentials", body)
                expect(status == (200 if venue == "okx" else 201), "ciphertext import and audit repair")
                package = imported["package"]
                expect(package["status"] == "pending_unlock" and not package["authenticated"], "HTTP import cannot authenticate AEAD")
                expect(package["venue"] == venue and package["account"] == "7", "public binding hints")
                expect(request("POST", "/api/credentials", body)[0] == 200, "identical upload is idempotent")
                inbox = root / "web/credential-packages" / (package["package_sha256"] + ".credential")
                expect(inbox.read_bytes() == encrypted, "ciphertext persisted unchanged")
                target = root / (venue + "-node")
                native("import", inbox, target, b"wrong-password\n", succeeds=False)
                unlocked = native("import", inbox, target)
                expect(unlocked["authenticated"] and unlocked["state"] == "staged", "native import authenticates before publication")
                native("import", inbox, target, succeeds=False)
                tampered = bytearray(encrypted)
                tampered[9] = 2 if venue != "binance" else 3
                tampered_path = root / f"{venue}-tampered.credential"
                tampered_path.write_bytes(tampered)
                native("import", tampered_path, root / (venue + "-tampered-node"), succeeds=False)
                activated = native("activate", config_path, target)
                expect(activated["state"] == "active" and activated["generation"] == 2
                       and not activated["trading_enabled"], "activation remains separate from trading")
                config.update(state="active", generation=2)
                config_path.write_text(json.dumps(config), encoding="utf-8")
                revoked = native("revoke", config_path, target)
                expect(revoked["state"] == "revoked" and revoked["generation"] == 3, "revocation is persisted")
                native("import", inbox, target, succeeds=False)
                expect(len(list(target.glob("*/execution.credential"))) == 1, "no overwrite or revival")
            status, listing = request("GET", "/api/credentials")
            expect(status == 200 and len(listing["packages"]) == 4, "all four venues listed")
            records = app.records.read_all()
            expect(len(records) == 4, "one audit per distinct import")
            for record in records:
                expect(set(record) == {"recorded_at", "kind", "package_sha256", "operator", "result"}, "audit allowlist")
            expect("encrypted_package" not in json.dumps(records), "ciphertext omitted from audit")
            original = next((root / "web/credential-packages").glob("*.credential"))
            original.write_bytes(b"corrupt")
            expect(request("GET", "/api/credentials")[0] == 400, "corrupt inbox fails closed")
            print("credential_enrollment_acceptance=passed venues=4 network=false")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            command_server.close()


if __name__ == "__main__":
    main()
