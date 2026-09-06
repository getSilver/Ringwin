"""End-to-end acceptance: browser-grade operator flow over the real backend.

login -> projection -> trading_pause (low-risk) -> enable_trading (high-risk
RiskWarning flow) -> kill_switch on a second shard -> OperatorRecord; every
step must land as replayable facts in the shard journals, proven by running
the projection probe directly over the persisted segments.
"""

import http.client
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from typing import Optional, Union

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control_plane
import control_plane_web
import owner_session

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = bytes(range(32))
PASSPHRASE = "correct horse battery staple"
RUNTIME = os.path.join(ROOT, ".scratch", "operator-ui-runtime")
WORKDIR = os.path.join(ROOT, ".scratch", "operator-ui-acceptance")


def build() -> dict:
    bins = {}
    for name in ("control_plane_node", "control_projection_probe"):
        out = os.path.join(ROOT, ".scratch", "build", f"{name}.exe")
        subprocess.run(["zig", "build-exe",
                        os.path.join(ROOT, "src", f"{name}.zig"),
                        "-O", "ReleaseSafe", f"-femit-bin={out}"],
                       check=True, cwd=ROOT)
        bins[name] = out
    return bins


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


class Client:
    def __init__(self, port: int):
        self.port = port

    def call(self, method: str, path: str, body=None) -> tuple[int, Union[dict, str]]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Content-Type": "application/json"}
        if getattr(self, "token", None):
            headers["Cookie"] = f"{control_plane_web.SESSION_COOKIE}={self.token}"
            headers["X-Owner-CSRF"] = self.csrf
        encoded = None if body is None else json.dumps(body).encode()
        conn.request(method, path, body=encoded, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        set_cookie = response.getheader("Set-Cookie") or ""
        conn.close()
        if "owner_session=" in set_cookie:
            self.token = set_cookie.split("owner_session=")[1].split(";")[0]
        if not raw or raw[:1] not in (b"{", b"["):
            return response.status, raw.decode("utf-8", "replace")
        return response.status, json.loads(raw)

    def wait_projection(self, predicate, timeout_seconds=15) -> list[dict]:
        deadline = time.time() + timeout_seconds
        last = []
        seen_status = None
        while time.time() < deadline:
            status, body = self.call("GET", "/api/projection")
            if seen_status is None:
                seen_status = (status, str(body)[:200])
                print(f"[projection first poll] {status} {str(body)[:200]}")
            if status == 200:
                last = body["shards"]
                if predicate(last):
                    return last
            time.sleep(0.4)
        raise SystemExit(f"projection never satisfied: {seen_status} {json.dumps(last)}")


def main() -> None:
    # A stray node from a crashed run would steal polled commands; clear it.
    subprocess.run(["taskkill", "/IM", "control_plane_node.exe", "/F"],
                   capture_output=True)
    bins = build()
    shutil.rmtree(RUNTIME, ignore_errors=True)
    shutil.rmtree(WORKDIR, ignore_errors=True)
    os.makedirs(WORKDIR)

    # Node setup writes genesis journals.
    subprocess.run([bins["control_plane_node"], "setup", RUNTIME], check=True,
                   cwd=ROOT)

    server = control_plane.CommandServer(KEY)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    app = control_plane_web.ControlPlaneApp(
        WORKDIR, server, projection_provider=control_plane_web.ProjectionProvider(
            RUNTIME, bins["control_projection_probe"]),
        ui_path=os.path.join(ROOT, "python", "operator_ui.html"))
    httpd = control_plane_web.serve(app)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    port = httpd.server_address[1]

    env = dict(os.environ, CONTROL_CHANNEL_KEY=KEY.hex())
    node = subprocess.Popen(
        [bins["control_plane_node"], "serve", RUNTIME, str(server.port), "300"],
        cwd=ROOT, env=env,
        stdout=open(os.path.join(WORKDIR, "node.log"), "w"), stderr=subprocess.STDOUT)

    try:
        client = Client(port)
        # Unauthenticated reads fail closed; UI page is served publicly.
        status, _ = client.call("GET", "/api/projection")
        expect(status == 401, "unauthenticated projection must be 401")
        status, _ = client.call("GET", "/")
        expect(status == 200, "ui page must load")

        # Setup + login.
        status, body = client.call("POST", "/setup", {"passphrase": PASSPHRASE})
        expect(status == 200, f"setup failed: {body}")
        secret = body["totp_secret"]
        code = owner_session.totp_at(secret, int(time.time()))
        time.sleep(owner_session.TOTP_STEP - int(time.time()) % owner_session.TOTP_STEP + 1)
        code = owner_session.totp_at(secret, int(time.time()))
        status, body = client.call("POST", "/login",
                                   {"passphrase": PASSPHRASE, "code": code})
        expect(status == 200, "login failed")
        # call() parsed the session cookie; keep the CSRF token for mutations.
        client.csrf = body["csrf_token"]

        # Both shards project authorized from genesis.
        shards = client.wait_projection(lambda v: len(v) == 4)
        expect(all(s["effective_authority"] for s in shards),
               f"genesis shards must be authorized: {shards}")

        # Low-risk pause on shard 1: draining -> progress -> ready.
        version = shards[0]["operational_version"]
        status, body = client.call("POST", "/command", {
            "kind": "trading_pause", "target_identity": 1,
            "expected_version": version})
        expect(status == 200, f"pause failed: {body}")
        shards = client.wait_projection(
            lambda v: not v[0]["effective_authority"]
            and v[0]["mode"] == "ready")
        print("pause_phase=ok")

        # High-risk re-enable via the RiskWarning flow.
        version = shards[0]["operational_version"]
        enable = {"kind": "enable_trading", "target_identity": 1,
                  "expected_version": version}
        status, warning = client.call("POST", "/risk-warning", enable)
        expect(status == 200, f"warning issue failed: {warning}")
        enable.update(risk_warning_acknowledged=True,
                      risk_warning_identity=int(warning["warning_identity"]))
        status, body = client.call("POST", "/command", enable)
        expect(status == 200, f"enable failed: {body}")
        shards = client.wait_projection(
            lambda v: v[0]["effective_authority"])
        print("enable_phase=ok")

        # Kill switch on shard 2.
        version = shards[1]["operational_version"]
        kill = {"kind": "kill_switch", "target_identity": 2,
                "expected_version": version}
        status, warning = client.call("POST", "/risk-warning", kill)
        expect(status == 200, f"warning issue failed: {warning}")
        kill.update(risk_warning_acknowledged=True,
                    risk_warning_identity=int(warning["warning_identity"]),
                    referenced_latch_identity=int(
                        warning["referenced_latch_identity"]))
        status, body = client.call("POST", "/command", kill)
        print(f"[kill submit] {status} {body} pending={len(server._pending)}")
        expect(status == 200, f"kill failed: {body}")
        shards = client.wait_projection(
            lambda v: not v[1]["effective_authority"]
            and v[1]["unresolved_latches"] == 1)
        print("kill_phase=ok")

        # Every step is replayable: projecting the persisted journals from
        # scratch reproduces exactly the served views.
        replayed = []
        for name in sorted(os.listdir(RUNTIME)):
            if name.endswith(".journal"):
                path = os.path.join(RUNTIME, name)
                with open(path, "rb") as handle:
                    hex_file = path + ".hex"
                    with open(hex_file, "w", newline="\n") as handle2:
                        handle2.write(handle.read().hex())
                result = subprocess.run(
                    [bins["control_projection_probe"], "project", hex_file],
                    capture_output=True, text=True, check=True)
                replayed.append(json.loads(result.stdout.strip()))
        for served, direct in zip(shards, replayed):
            for field in ("mode", "effective_authority",
                          "unresolved_latches", "operational_version"):
                expect(served[field] == direct[field],
                       f"replay mismatch {field}: served={served} direct={direct}")
        print("replay_phase=ok")

        status, body = client.call("GET", "/operator-records")
        expect(len(body["records"]) >= 3,
               f"expected at least three operator records: {len(body['records'])}")
        print("records_phase=ok")
        print("operator_ui_acceptance=passed")
    finally:
        node.terminate()


if __name__ == "__main__":
    main()


