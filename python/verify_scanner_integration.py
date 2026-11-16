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
from test_scanner_integration import ProtocolTransport, DynamicOkxTransport, DynamicHyperliquidTransport, RefreshTransport
from unittest.mock import patch


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui",required=True)
    parser.add_argument("--dynamic-okx", action="store_true")
    parser.add_argument("--dynamic-hyperliquid", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--large-catalogue", action="store_true")
    args=parser.parse_args()
    if args.large_catalogue and (args.dynamic_okx or args.dynamic_hyperliquid):
        parser.error("--large-catalogue requires the combined sources")
    with tempfile.TemporaryDirectory(prefix="ringwin-scanner-internal-") as directory:
        now=[2_000_000_000,1_800_000_000_000_000_000]
        transport=DynamicHyperliquidTransport(now) if args.dynamic_hyperliquid else DynamicOkxTransport(now) if args.dynamic_okx else ProtocolTransport(now)
        if args.refresh:
            if args.dynamic_okx or args.dynamic_hyperliquid:
                transport = RefreshTransport(now, args.dynamic_hyperliquid)
            else:
                transport.okx, transport.hl = RefreshTransport(now), RefreshTransport(now, True)
        if args.large_catalogue:
            hl = transport.hl.base if args.refresh else transport.hl
            hl.metadata_document["universe"] += [dict(name="COIN"+str(n), szDecimals=4, maxLeverage=25, marginTableId=53) for n in range(64)]
        channel=control_plane.CommandServer(b"f"*32)
        owner_time=int(time.time())
        def assemble():
            with patch("opportunity_scanner.scanner_runtime.PublicTransport", return_value=transport):
                application=control_plane_web.ControlPlaneApp(directory,channel,ui_path=args.ui,clock=lambda:owner_time)
            feeds=application.scanner_runtime
            feeds.closing.set()
            feeds.thread.join(timeout=15)
            feeds.clock=lambda:now[0]
            feeds.utc_clock=lambda:now[1]
            feeds.console.clock=feeds.clock
            feeds.closing.clear()
            return application, feeds
        app, runtime=assemble()
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
                if command == "restart":
                    closing.set(); publisher.join(timeout=15)
                    port=server.server_port
                    server.shutdown(); server.server_close(); thread.join()
                    runtime.close(); channel.close()
                    channel=control_plane.CommandServer(b"f"*32)
                    owner_time+=60
                    requests=len(transport.requests)
                    app,runtime=assemble()
                    server=type(server)(("127.0.0.1",port),control_plane_web.make_handler(app))
                    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
                    closing.clear()
                    publisher=threading.Thread(target=publish,daemon=True); publisher.start()
                    print(json.dumps(dict(command=command,requests=requests,after=len(transport.requests),
                        totp=owner_session.totp_at(app.totp.read_secret(),app.clock()))),flush=True)
                if command == "requests":
                    print(json.dumps(dict(command=command,requests=len(transport.requests))),flush=True)
                if command.startswith("catalogue-") and args.refresh:
                    parts=command.split("-",2)
                    if len(parts)==3:
                        kind,mode=parts[1:]
                        (transport.okx if kind=="okx" else transport.hl).mode=mode
                        setting=next(s for s in app.exchange_settings_store.view()["exchanges"] if s["type"]==kind)
                    else:
                        transport.mode=parts[1]
                        setting=app.exchange_settings_store.view()["exchanges"][0]
                    runtime.discover(setting)
        finally:
            closing.set(); publisher.join(timeout=15)
            server.shutdown(); server.server_close(); thread.join()
            runtime.close(); channel.close()


if __name__ == "__main__": main()
