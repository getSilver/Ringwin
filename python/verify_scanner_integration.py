"""Offline browser node: only transport supplies synthetic Venue protocol bytes."""
import argparse
import json
import sys
import tempfile
import threading
import time

import control_plane
import control_plane_web
import owner_session
from scanner_runtime import ScannerRuntime
from test_scanner_integration import ProtocolTransport, configuration


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui",required=True)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ringwin-scanner-internal-") as directory:
        now=[2_000_000_000,1_800_000_000_000_000_000]
        transport=ProtocolTransport(now)
        runtime=ScannerRuntime(directory,configuration(),transport=transport,
            clock=lambda:now[0],utc_clock=lambda:now[1],automatic=False)
        channel=control_plane.CommandServer(b"f"*32)
        owner_time=int(time.time())
        app=control_plane_web.ControlPlaneApp(directory,channel,scanner_console=runtime.console,ui_path=args.ui,clock=lambda:owner_time)
        passphrase="synthetic-internal-integration-only"
        app.setup(passphrase)
        server=control_plane_web.serve(app)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        closing=threading.Event()
        def publish():
            while not closing.wait(.2):
                if runtime.console.desired == "running":
                    now[0]+=100_000_000; now[1]+=100_000_000
                    runtime.step()
        publisher=threading.Thread(target=publish,daemon=True); publisher.start()
        print(json.dumps(dict(port=server.server_port,passphrase=passphrase,
            totp=owner_session.totp_at(app.totp.read_secret(),app.clock()),
            totp_next=owner_session.totp_at(app.totp.read_secret(),app.clock()+owner_session.TOTP_STEP))),flush=True)
        try:
            for line in sys.stdin:
                command=line.strip()
                if command == "quit": break
                if command == "disconnect": transport.fail.add(21)
                if command == "reconnect": transport.fail.clear()
                if command == "expire": now[0]+=6_000_000_000
        finally:
            closing.set(); publisher.join(timeout=15)
            server.shutdown(); server.server_close(); thread.join()
            runtime.close(); channel.close()


if __name__ == "__main__": main()
