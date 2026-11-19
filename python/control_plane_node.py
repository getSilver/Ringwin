"""Run the existing authenticated Web control plane with configured public scanning."""
import argparse
import getpass
import json
import os
from pathlib import Path
import secrets

from control_plane import CommandServer
from control_plane_web import ControlPlaneApp, ProjectionProvider, make_handler
from http.server import ThreadingHTTPServer


DEFAULT_PROJECTION_PROBE = Path(__file__).resolve().parents[1] / "zig-out" / "bin" / (
    "ringwin-control-projection.exe" if os.name == "nt" else "ringwin-control-projection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ui", type=Path, required=True)
    parser.add_argument("--core-directory", type=Path, help="Directory containing the core shard journals")
    parser.add_argument("--projection-probe", type=Path, default=DEFAULT_PROJECTION_PROBE)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    core_directory = args.core_directory or args.directory
    if not core_directory.is_dir():
        parser.error("--core-directory must be an existing directory")
    provider = ProjectionProvider(str(core_directory.resolve()), str(args.projection_probe.resolve()))
    app = ControlPlaneApp(str(args.directory), CommandServer(secrets.token_bytes(32)),
                          ui_path=args.ui, asset_provider=provider.asset_bindings)
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
