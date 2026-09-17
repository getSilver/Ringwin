import sys, os, json, time, threading, subprocess, shutil
sys.path.insert(0, "python")
import control_plane

ROOT = os.getcwd()
KEY = bytes(range(32))
RUNTIME = os.path.join(ROOT, ".scratch", "debug-node-runtime")
shutil.rmtree(RUNTIME, ignore_errors=True)
os.makedirs(RUNTIME, exist_ok=True)

NODE = os.path.join(ROOT, ".scratch", "build", "control_plane_node.exe")
subprocess.run([NODE, "setup", RUNTIME], check=True)

server = control_plane.CommandServer(KEY)
threading.Thread(target=server.serve_forever, daemon=True).start()

env = dict(os.environ, CONTROL_CHANNEL_KEY=KEY.hex())
node = subprocess.Popen([NODE, "serve", RUNTIME, str(server.port), "200"],
                        env=env, cwd=ROOT)
time.sleep(1)

server.enqueue({"command_identity": 77, "kind": "kill_switch", "target_identity": 2,
                "expected_version": 3, "expires_at": int(time.time()) + 600,
                "referenced_latch_identity": 77})
time.sleep(2)
with open(os.path.join(RUNTIME, "shard-2.journal"), "rb") as h:
    data = h.read()
print("shard-2 bytes:", len(data))
hex_file = os.path.join(RUNTIME, "s2.hex")
open(hex_file, "w").write(data.hex())
r = subprocess.run([os.path.join(ROOT, ".scratch", "build", "control_projection_probe.exe"),
                    "project", hex_file], capture_output=True, text=True)
print(r.stdout.strip()[:400])
print(r.stderr[:500])
node.terminate()



