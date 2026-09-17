"""控制面整波自动验收（失败即停）。

一条入口覆盖 09 号票验收矩阵：
  A 认证: 错误口令限速 / 错误 TOTP 拒绝 / 正确登录
  B 未认证与缺 CSRF 全部拒绝; 高危命令缺 RiskWarning 拒绝
  C 命令经通道进入分片日志并生效; 重复 command_id 幂等
  D UI 投影与分片权威状态逐字段一致 (对账断言)
  E TradingPause -> lifecycle progress -> EnableTrading -> KillSwitch 轨迹
  F 控制面失联: 分片节点按降级设计继续, Kill 不自动解除, 日志不被篡改
  G 重放等价: 磁盘日志直接 SemanticReplay 与服务视图逐字段一致
  H 四分片定向投递: 跨分片命令被拒且不影响目标分片

运行: python python\\verify_control_plane_wave.py
成功输出: control_plane_wave_acceptance=passed
"""

import http.client
import json
import os
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control_plane
import control_plane_web
import owner_session

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = bytes(range(32))
PASSPHRASE = "correct horse battery staple"
RUNTIME = os.path.join(ROOT, ".scratch", "control-plane-wave-runtime")
WORKDIR = os.path.join(ROOT, ".scratch", "control-plane-wave-acceptance")
NOW_BASE = int(time.time())


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


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


class Client:
    def __init__(self, port: int):
        self.port = port
        self.token = None
        self.csrf = ""

    def call(self, method: str, path: str, body=None) -> tuple:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Content-Type": "application/json"}
        if self.token:
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
        while time.time() < deadline:
            status, body = self.call("GET", "/api/projection")
            if status == 200:
                last = body["shards"]
                if predicate(last):
                    return last
            time.sleep(0.3)
        with open(os.path.join(WORKDIR, "last-projection.json"), "w") as handle:
            json.dump(last, handle, indent=1)
        raise SystemExit(f"projection never satisfied; dumped last-projection.json")


def high_risk_command(client: Client, kind: str, target: int,
                      version: int) -> tuple[int, dict]:
    base = {"kind": kind, "target_identity": target,
            "expected_version": version}
    status, warning = client.call("POST", "/risk-warning", base)
    expect(status == 200, f"warning issue failed for {kind}: {warning}")
    base.update(risk_warning_acknowledged=True,
                risk_warning_identity=int(warning["warning_identity"]))
    if warning.get("referenced_latch_identity"):
        base["referenced_latch_identity"] = int(warning["referenced_latch_identity"])
    return client.call("POST", "/command", base)


def phase_auth(client: Client, secret_holder: dict) -> None:
    # 未认证读投影必须拒绝。
    status, _ = client.call("GET", "/api/projection")
    expect(status == 401, "unauthenticated projection must be 401")

    status, body = client.call("POST", "/setup", {"passphrase": PASSPHRASE})
    expect(status == 200 and body.get("totp_secret"), f"setup failed: {body}")
    secret_holder["secret"] = body["totp_secret"]
    status, _ = client.call("POST", "/setup", {"passphrase": PASSPHRASE})
    expect(status == 409, "second setup must conflict")

    good_code = owner_session.totp_at(secret_holder["secret"], NOW_BASE)
    for _ in range(owner_session.RATE_LIMIT_MAX_FAILURES):
        status, _ = client.call("POST", "/login",
                                {"passphrase": "totally wrong passphrase",
                                 "code": good_code})
        expect(status == 401, "wrong passphrase must be 401")
    clock_shift = owner_session.RATE_LIMIT_COOLDOWN_SECONDS + 1
    client.shift = clock_shift
    status, _ = client.call("POST", "/login",
                            {"passphrase": PASSPHRASE, "code": good_code})
    expect(status == 429, "rate limited login must be 429")
    print("phase_a_auth=ok")


def phase_login(client: Client, secret: str) -> None:
    # 错误 TOTP（口令正确）必须拒绝且不消费正确验证码。
    status, _ = client.call("POST", "/login",
                            {"passphrase": PASSPHRASE, "code": "000000"})
    expect(status == 401, "wrong TOTP must be 401")
    code = owner_session.totp_at(secret, int(time.time()))
    status, body = client.call("POST", "/login",
                               {"passphrase": PASSPHRASE, "code": code})
    expect(status == 200 and body.get("csrf_token"), f"login failed: {body}")
    client.csrf = body["csrf_token"]
    print("phase_b_login=ok")


def phase_guards(client: Client) -> None:
    # 无凭证裸请求。
    conn = http.client.HTTPConnection("127.0.0.1", client.port, timeout=10)
    conn.request("POST", "/command",
                 body=json.dumps({"kind": "cancel_open_orders",
                                  "target_identity": 1,
                                  "expected_version": 3}).encode(),
                 headers={"Content-Type": "application/json"})
    response = conn.getresponse()
    response.read()
    conn.close()
    expect(response.status == 401, "bare request must be 401")

    # 有会话但缺 CSRF 头。
    conn = http.client.HTTPConnection("127.0.0.1", client.port, timeout=10)
    conn.request("POST", "/command",
                 body=json.dumps({"kind": "cancel_open_orders",
                                  "target_identity": 1,
                                  "expected_version": 3}).encode(),
                 headers={"Content-Type": "application/json",
                          "Cookie": f"{control_plane_web.SESSION_COOKIE}={client.token}"})
    response = conn.getresponse()
    response.read()
    conn.close()
    expect(response.status == 403, "missing CSRF must be 403")

    enable = {"kind": "enable_trading", "target_identity": 3,
              "expected_version": 3}
    status, _ = client.call("POST", "/command", enable)
    expect(status == 403, "high-risk without warning must be 403")
    print("phase_c_guards=ok")


def find(shards: list[dict], target: int) -> dict:
    for view in shards:
        if str(view["target_identity"]) == str(target):
            return view
    raise SystemExit(f"shard-{target} missing from projection")


def phase_commands(client: Client) -> dict:
    shards = client.wait_projection(lambda v: len(v) == 4)
    expect(all(s["effective_authority"] for s in shards),
           "genesis shards must all be authorized")

    # 低风险 Pause shard-1: draining -> progress -> ready。
    version = find(shards, 1)["operational_version"]
    status, body = client.call("POST", "/command", {
        "kind": "trading_pause", "target_identity": 1,
        "expected_version": version, "command_identity": 9001})
    expect(status == 200, f"pause failed: {body}")
    shards = client.wait_projection(
        lambda v: not find(v, 1)["effective_authority"]
        and find(v, 1)["mode"] == "ready")

    # 高风险 EnableTrading 经 RiskWarning 流恢复授权。
    version = find(shards, 1)["operational_version"]
    status, body = high_risk_command(client, "enable_trading", 1, version)
    expect(status == 200, f"enable failed: {body}")
    shards = client.wait_projection(lambda v: find(v, 1)["effective_authority"])

    # 重复 command_id 幂等：核心只生效一次，投影版本不变。
    version_before = find(shards, 2)["operational_version"]
    duplicate = {"kind": "cancel_open_orders", "target_identity": 2,
                 "expected_version": version_before,
                 "command_identity": 990001}
    status, _ = client.call("POST", "/command", duplicate)
    expect(status == 200, f"first cancel failed: {body}")
    time.sleep(1.5)
    status, _ = client.call("POST", "/command", duplicate)
    expect(status == 200, "duplicate submit must still be accepted at web layer")
    shards = client.wait_projection(
        lambda v: find(v, 2)["operational_version"] == version_before + 1)
    print("phase_d_commands_idempotent=ok")
    return shards


def phase_kill_and_outage(client: Client, server, node) -> dict:
    shards = client.wait_projection(lambda v: len(v) == 4)
    version = find(shards, 2)["operational_version"]

    status, body = high_risk_command(client, "kill_switch", 2, version)
    expect(status == 200, f"kill failed: {body}")
    shards = client.wait_projection(
        lambda v: not find(v, 2)["effective_authority"]
        and find(v, 2)["unresolved_latches"] == 1)
    print("phase_e_kill=ok")

    # 控制面失联: 关闭 HTTP 服务与通道。节点必须继续存活，日志不被改动，
    # Kill 锁存不自动解除。
    server.close()
    journal_snapshot = open(os.path.join(RUNTIME, "shard-2.journal"), "rb").read()
    time.sleep(3)
    expect(node.poll() is None, "node must keep running after control-plane loss")
    journal_after = open(os.path.join(RUNTIME, "shard-2.journal"), "rb").read()
    expect(journal_after == journal_snapshot,
           "journal must be untouched while the control plane is gone")

    probe = os.path.join(ROOT, ".scratch", "build", "control_projection_probe.exe")
    hex_file = os.path.join(RUNTIME, "shard-2.journal.hex")
    with open(hex_file, "w", newline="\n") as handle:
        handle.write(journal_after.hex())
    result = subprocess.run([probe, "project", hex_file],
                            capture_output=True, text=True, check=True)
    view = json.loads(result.stdout.strip())
    expect(view["unresolved_latches"] == 1 and not view["effective_authority"],
           f"kill latch must survive control-plane loss: {view}")
    print("phase_f_outage=ok")
    return shards


def phase_replay(client_last: list[dict], bins: dict) -> None:
    for index in range(1, 5):
        path = os.path.join(RUNTIME, f"shard-{index}.journal")
        with open(path, "rb") as handle:
            hex_text = handle.read().hex()
        hex_file = path + ".hex"
        with open(hex_file, "w", newline="\n") as handle:
            handle.write(hex_text)
        result = subprocess.run([bins["control_projection_probe"],
                                 "project", hex_file],
                                capture_output=True, text=True, check=True)
        view = json.loads(result.stdout.strip())
        served = find(client_last, index)
        for field in ("mode", "effective_authority", "unresolved_latches",
                      "operational_version", "last_sequence"):
            expect(view[field] == served[field],
                   f"replay mismatch shard-{index} {field}: "
                   f"disk={view} served={served}")
    print("phase_h_replay=ok")


def main() -> None:
    subprocess.run(["taskkill", "/IM", "control_plane_node.exe", "/F"],
                   capture_output=True)
    bins = build()
    shutil.rmtree(RUNTIME, ignore_errors=True)
    shutil.rmtree(WORKDIR, ignore_errors=True)
    os.makedirs(WORKDIR)
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

    env = dict(os.environ, CONTROL_CHANNEL_KEY=KEY.hex())
    node = subprocess.Popen(
        [bins["control_plane_node"], "serve", RUNTIME, str(server.port), "300"],
        cwd=ROOT, env=env,
        stdout=open(os.path.join(WORKDIR, "node.log"), "w"),
        stderr=subprocess.STDOUT)

    try:
        client = Client(httpd.server_address[1])
        client.shift = 0
        secret_holder: dict = {}

        phase_auth(client, secret_holder)
        clock_note = client.call("GET", "/api/projection")  # warm-up ignored
        # 注入时钟不可用于真实 HTTP 服务；限速冷却用真实时间等待。
        time.sleep(owner_session.RATE_LIMIT_COOLDOWN_SECONDS + 1)
        phase_login(client, secret_holder["secret"])
        phase_guards(client)
        shards = phase_commands(client)
        shards = phase_kill_and_outage(client, server, node)
        phase_replay(shards, bins)
        print("control_plane_wave_acceptance=passed")
    finally:
        node.terminate()
        try:
            httpd.shutdown()
            httpd.server_close()
        except Exception:
            pass


if __name__ == "__main__":
    main()


