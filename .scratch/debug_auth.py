import sys, os, json, time, threading, http.client
sys.path.insert(0, "python")
import control_plane, control_plane_web, owner_session

KEY = bytes(range(32))
WORKDIR = ".scratch\\debug-web2"
os.makedirs(WORKDIR, exist_ok=True)
for f in os.listdir(WORKDIR):
    os.remove(os.path.join(WORKDIR, f))

server = control_plane.CommandServer(KEY)
threading.Thread(target=server.serve_forever, daemon=True).start()
app = control_plane_web.ControlPlaneApp(WORKDIR, server)
httpd = control_plane_web.serve(app)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

def call(method, path, body=None, cookie="", csrf=""):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if cookie:
        headers["Cookie"] = f"owner_session={cookie}"
        headers["X-Owner-CSRF"] = csrf
    conn.request(method, path,
                 body=None if body is None else json.dumps(body).encode(),
                 headers=headers)
    r = conn.getresponse()
    sc = r.getheader("Set-Cookie") or ""
    out = r.read()
    conn.close()
    return r.status, out.decode(), sc

status, body, sc = call("POST", "/setup", {"passphrase": "correct horse battery staple"})
print("setup", status)
secret = json.loads(body)["totp_secret"]
time.sleep(owner_session.TOTP_STEP - int(time.time()) % owner_session.TOTP_STEP + 1)
code = owner_session.totp_at(secret, int(time.time()))
status, body, sc = call("POST", "/login", {"passphrase": "correct horse battery staple", "code": code})
print("login", status, body[:120])
print("set-cookie:", sc)
token = sc.split("session_token=")[1].split(";")[0]
csrf = json.loads(body)["csrf_token"]
status, body, _ = call("GET", "/api/projection", cookie=token, csrf=csrf)
print("projection", status, str(body)[:120])
