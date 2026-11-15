"""Run the existing authenticated Web control plane with configured public scanning."""
import argparse
import getpass
import json
from pathlib import Path
import secrets

from control_plane import CommandServer
from control_plane_web import ControlPlaneApp, make_handler
from http.server import ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ui", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    # This public-only assembly has no core command consumer or authority bridge.
    app = ControlPlaneApp(str(args.directory), CommandServer(secrets.token_bytes(32)), ui_path=args.ui)
    if not app.passphrases.exists():
        status, result = app.setup(getpass.getpass("Owner passphrase: "))
        if status != 200:
            raise ValueError(result)
        print(json.dumps(result))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(app))
    server.daemon_threads = True
    print("Web control plane: http://127.0.0.1:" + str(server.server_port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if app.scanner_runtime:
            app.scanner_runtime.close()
        elif app.scanner_console:
            app.scanner_console.close()
        app.command_server.close()


if __name__ == "__main__":
    main()
