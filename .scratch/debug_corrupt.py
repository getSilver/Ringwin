import sys, os, time, threading, subprocess
sys.path.insert(0, "python")
import control_plane

ROOT = os.getcwd()
KEY = bytes(range(32))
RUNTIME = ".scratch\\debug-corrupt-runtime"
shutil = __import__("shutil")
shutil.rmtree(RUNTIME, ignore_errors=True); os.makedirs(RUNTIME)
NODE = os.path.join(ROOT, ".scratch", "build", "control_plane_node.exe")
subprocess.run([NODE, "setup", RUNTIME], check=True)

server = control_plane.CommandServer(KEY)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, CONTROL_CHANNEL_KEY=KEY.hex())
node = subprocess.Popen([NODE, "serve", RUNTIME, str(server.port), "200"],
                        env=env, cwd=ROOT)
time.sleep(0.5)

good = control_plane.sign_command({"command_identity": 5, "target_identity": 2,
    "expected_version": 3, "expires_at": int(time.time())+600,
    "kind": "kill_switch", "referenced_latch_identity": 77}, KEY)
evil = bytearray(good); evil[-1] ^= 0xFF
server._pending.append(control_plane.frame(bytes(evil)))
# 再放一个正确的, 验证坏的不影响好的
server._pending.append(control_plane.frame(good))
time.sleep(1.5)
node.terminate(); node.wait()
print("=== done ===")
