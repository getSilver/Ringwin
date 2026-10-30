import sys, os, json, time, threading, subprocess, hashlib, hmac, struct
sys.path.insert(0, "python")
import control_plane, control_plane_web, owner_session

ROOT = os.getcwd()
KEY = bytes(range(32))
WORKDIR = ".scratch\\debug-web3"
RUNTIME = ".scratch\\debug-node-runtime3"
shutil = __import__("shutil")
for d in (WORKDIR, RUNTIME):
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d, exist_ok=True)

NODE = os.path.join(ROOT, ".scratch", "build", "control_plane_node.exe")
subprocess.run([NODE, "setup", RUNTIME], check=True)

server = control_plane.CommandServer(KEY)
threading.Thread(target=server.serve_forever, daemon=True).start()
app = control_plane_web.ControlPlaneApp(WORKDIR, server)
httpd = control_plane_web.serve(app)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

env = dict(os.environ, CONTROL_CHANNEL_KEY=KEY.hex())
node = subprocess.Popen([NODE, "serve", RUNTIME, str(server.port), "30000"],
                        env=env, cwd=ROOT,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)

# --- 通过 HTTP 走一遍 warning -> kill ---
import http.client
token = csrf = None
def call(method, path, body=None):
    global token, csrf
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Cookie"] = f"owner_session={token}"
        headers["X-Owner-CSRF"] = csrf or ""
    conn.request(method, path, body=json.dumps(body or {}).encode(), headers=headers)
    r = conn.getresponse(); raw = r.read()
    sc = r.getheader("Set-Cookie") or ""
    conn.close()
    if "owner_session=" in sc:
        token = sc.split("owner_session=")[1].split(";")[0]
    if raw[:1] == b"{" and b"csrf_token" in raw:
        csrf = json.loads(raw)["csrf_token"]
    return r.status, json.loads(raw) if raw[:1] == b"{" else raw

PASSPHRASE = "correct horse battery staple"
call("POST", "/setup", {"passphrase": PASSPHRASE})
secret = None
with open(os.path.join(WORKDIR, "totp.secret")) as h:
    secret = h.read().strip()
time.sleep(owner_session.TOTP_STEP - int(time.time()) % owner_session.TOTP_STEP + 1)
code = owner_session.totp_at(secret, int(time.time()))
print("login:", call("POST", "/login", {"passphrase": PASSPHRASE, "code": code})[0])

kill = {"kind": "kill_switch", "target_identity": 2, "expected_version": 3}
st, warn = call("POST", "/risk-warning", kill)
print("warning:", st)
kill.update(risk_warning_acknowledged=True,
            risk_warning_identity=int(warn["warning_identity"]))
st, body = call("POST", "/command", kill)
print("submit:", st, body)

frame = server._pending[0]
envelope = frame[4:]
print("envelope len:", len(envelope))
mac = envelope[1:33]; cmd_bytes = envelope[33:]
msg = envelope[:1] + cmd_bytes
expect_mac = hmac.new(KEY, msg, hashlib.sha256).digest()
print("mac ok:", hmac.compare_digest(mac, expect_mac))
fields = struct.unpack("<QQQQQQQQBqQQBQQ", cmd_bytes)
names = [("command_identity",16),("content_hash",16),("target_identity",16),
         ("expected_version",8),("expires_at",8),("kind",1),
         ("target_position",8),("referenced_latch",16),("ack",1),
         ("warn_id",16)]
idx = 0
vals = []
for n, size in names:
    raw_b = cmd_bytes[idx:idx+size]; idx += size
    if size == 1:
        vals.append((n, raw_b[0]))
    else:
        vals.append((n, int.from_bytes(raw_b, "little")))
decoded = dict(vals)
embedded = decoded["content_hash"]
recomputed = control_plane.content_hash({
  "command_identity": decoded["command_identity"],
  "content_hash": 0,
  "target_identity": decoded["target_identity"],
  "expected_version": decoded["expected_version"],
  "expires_at": decoded["expires_at"],
  "kind": [k for k,v in control_plane.KIND.items() if v == decoded["kind"]][0],
  "target_position": decoded["target_position"],
  "referenced_latch_identity": decoded["referenced_latch"],
  "risk_warning_acknowledged": bool(decoded["ack"]),
  "risk_warning_identity": decoded["warn_id"],
})
print("embedded:", embedded)
print("recomputed:", recomputed)
print("hash match:", embedded == recomputed)
hex_path = os.path.abspath("shard-kill.hex").replace("\\", "/")
with open("shard-kill.hex", "w", newline="\n") as h:
    h.write(envelope.hex())
print("py envelope0:", envelope[0], "hex head:", envelope.hex()[:16])
r = subprocess.run(["zig", "run", "src/debug_verify_tmp.zig", "--", "shard-kill.hex", KEY.hex()],
                   capture_output=True, text=True, cwd=ROOT)
print("ZIG:", r.stdout.strip(), r.stderr.strip()[:400])
node.terminate()







print("py envelope0:", envelope[0], "hex head:", envelope.hex()[:16])
