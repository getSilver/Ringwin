"""Verify the default Web launcher against a formal Linux engine and an isolated Writer."""
import contextlib
import http.client
import json
import os
from pathlib import Path
import secrets
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import owner_session


def receive(stream, size):
    data = bytearray()
    while len(data) < size:
        part = stream.recv(size - len(data))
        if not part:
            raise EOFError("authority connection closed")
        data.extend(part)
    return data


def relay_strategy_reads(web, engine):
    try:
        while True:
            header = receive(web, 5)
            size, = struct.unpack("<I", header[1:])
            if header[0:1] != b"P" or not 0 < size <= 256 * 1024:
                raise ValueError("invalid strategy query")
            engine.sendall(header + receive(web, size))
            reply = receive(engine, 4)
            size, = struct.unpack("<I", reply)
            if not 0 < size <= 256 * 1024:
                raise ValueError("invalid strategy reply")
            web.sendall(reply + receive(engine, size))
    except (EOFError, OSError, ValueError):
        web.close()


@contextlib.contextmanager
def child(args, **kwargs):
    with subprocess.Popen(args, **kwargs) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)


def request(port, path, *, credentials=None, session=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        headers = {"Cookie": "owner_session=" + session["session_token"],
                   "X-Owner-CSRF": session["csrf_token"]} if session else {}
        connection.request("POST" if credentials else "GET", path,
                           json.dumps(credentials) if credentials else None, headers=headers)
        response = connection.getresponse()
        return response.status, json.load(response)
    finally:
        connection.close()


def verify(engine_binary, provision_binary, *, approved):
    python = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="rw07-") as directory:
        state = Path(directory, "core")
        state.mkdir()
        subprocess.run([provision_binary, str(state), "--web-approved" if approved else "--web-empty"],
                       check=True, timeout=30)
        control = str(Path(directory, "engine.sock"))
        with child([engine_binary, "--production-role", "engine", "--socket", control,
                    "--state-dir", str(state)]) as engine:
            with socket.socket(socket.AF_UNIX) as controller:
                controller.settimeout(10)
                for _ in range(100):
                    try:
                        controller.connect(control)
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        if engine.poll() is not None:
                            raise RuntimeError("formal engine exited during startup")
                        time.sleep(0.05)
                else:
                    raise RuntimeError("formal engine socket did not start")

                assert receive(controller, 2) == b"HV"
                web_state = Path(directory, "web")
                web_state.mkdir()
                password = secrets.token_urlsafe(24)
                owner_session.PassphraseStore(str(web_state)).set(password)
                totp = owner_session.TotpStore(str(web_state)).initialize()
                operator, relay = socket.socketpair()
                with operator, relay:
                    worker = threading.Thread(target=relay_strategy_reads, args=(relay, controller), daemon=True)
                    worker.start()
                    cmd = [sys.executable, str(python / "control_plane_node.py"), "--directory", str(web_state),
                           "--core-directory", str(state), "--ui", str(python / "operator_ui.html"),
                           "--port", "0", "--engine-authority-fd", str(operator.fileno())]
                    with child(cmd, stdout=subprocess.PIPE, text=True, pass_fds=(operator.fileno(),)) as web:
                        operator.close()
                        if not select.select([web.stdout], [], [], 15)[0]:
                            raise RuntimeError("Web launcher did not become ready")
                        started = web.stdout.readline().strip()
                        assert started.startswith("Web control plane:"), started
                        port = int(started.rsplit(":", 1)[1])
                        status, _ = request(port, "/api/strategy-instances")
                        assert status == 401, status
                        status, login = request(port, "/login", credentials=dict(passphrase=password,
                                                code=owner_session.totp_at(totp, int(time.time()))))
                        assert status == 200, status
                        status, result = request(port, "/api/strategy-instances", session=login)
                        assert status == 200, (status, result)
                        instance, = result["instances"]
                        assert instance["binding"]["strategy_identity"] == f"{9:032x}", instance
                        assert instance["binding"]["decision_domain"] == f"{1:032x}", instance
                        assert result["read_only"] is True
                        assert instance["trading_authorized"] is False
                        assert instance["pair_trading_list_empty"] is not approved
                        expected_pairs = [dict(identity=f"{98765:032x}", direction=1, mode="taker_taker",
                            legs=[dict(venue=venue, environment="simulation", account=f"{account:032x}",
                                       instrument=f"{instrument:032x}")
                                  for venue, account, instrument in ((1, 20, 101), (21, 30, 102))])] if approved else []
                        assert instance["pair_trading_list"] == expected_pairs, instance
                        engine.kill()
                        engine.wait(timeout=15)
                        status, result = request(port, "/api/strategy-instances", session=login)
                        assert status == 503 and result["error"], (status, result)
                    worker.join(timeout=5)
                    assert not worker.is_alive()


def main(engine_binary, provision_binary):
    for approved in (False, True):
        verify(engine_binary, provision_binary, approved=approved)
    print("production_strategy_web: recovery_only=pass empty_pair_list=pass approved_pair_list=pass disconnect=pass")


if __name__ == "__main__":
    main(*map(os.path.abspath, sys.argv[1:]))
