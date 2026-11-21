"""Run the existing authenticated Web control plane with configured public scanning."""
import argparse
from contextlib import ExitStack, contextmanager
import getpass
import json
import os
from pathlib import Path
from types import SimpleNamespace
import secrets
import socket
import struct
import threading

import strategy_package

from control_plane import CommandServer
from control_plane_web import ControlPlaneApp, ProjectionProvider, make_handler
from http.server import ThreadingHTTPServer


DEFAULT_PROJECTION_PROBE = Path(__file__).resolve().parents[1] / "zig-out" / "bin" / (
    "ringwin-control-projection.exe" if os.name == "nt" else "ringwin-control-projection")


class EnginePairList:
    """Read through the engine control connection authenticated by the node supervisor."""

    max_frame_bytes = 256 * 1024

    def __init__(self, stream):
        self.stream = stream
        stream.settimeout(3)
        self.lock = threading.Lock()

    def receive(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.stream.recv(size - len(result))
            if not chunk:
                raise OSError("engine authority disconnected")
            result.extend(chunk)
        return result

    def request(self, value):
        strategy_package.require(value.get("operation") == "pair_trading_list",
                                 "engine strategy operation unavailable")
        data = strategy_package.canonical(value)
        strategy_package.require(len(data) <= self.max_frame_bytes, "engine request too large")
        with self.lock:
            try:
                self.stream.sendall(b"P" + struct.pack("<I", len(data)) + data)
                size, = struct.unpack("<I", self.receive(4))
                if not 0 < size <= self.max_frame_bytes:
                    raise OSError("invalid engine response size")
                result = json.loads(self.receive(size))
                if type(result) is not dict or not (
                        set(result) == {"pairs"} and (result["pairs"] is None or type(result["pairs"]) is list)
                        or set(result) == {"error"} and type(result["error"]) is str):
                    raise OSError("invalid engine response")
            except (OSError, ValueError):
                self.stream.close()
                raise
        strategy_package.require("error" not in result, result.get("error", "engine rejected request"))
        return result


@contextmanager
def open_node_web(*, directory, ui_path, port, projection, command_server, release_manager=None,
                  lifecycle_outbox=None, instance_source=None):
    """Open the Web control plane. The node drives committed input via app.instance_manager."""
    if instance_source is not None and instance_source.authority is None:
        raise ValueError("strategy instance access requires node authority")
    if (release_manager is None) != (lifecycle_outbox is None):
        raise ValueError("strategy release management requires a lifecycle outbox")

    with ExitStack() as cleanup:
        cleanup.callback(command_server.close)
        app = ControlPlaneApp(str(directory), command_server, ui_path=str(ui_path),
                              projection_provider=projection, release_manager=release_manager,
                              lifecycle_outbox=lifecycle_outbox, instance_source=instance_source)
        cleanup.callback(app.scanner_runtime.close)
        if app.instance_manager is not None:
            cleanup.callback(app.instance_manager.close)
        if not app.passphrases.exists():
            status, result = app.setup(getpass.getpass("Owner passphrase: "))
            if status != 200:
                raise ValueError(result)
            print(json.dumps(result))
        with ThreadingHTTPServer(("127.0.0.1", port), make_handler(app)) as server:
            server.daemon_threads = True
            yield app, server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ui", type=Path, required=True)
    parser.add_argument("--core-directory", type=Path, help="Directory containing the core shard journals")
    parser.add_argument("--projection-probe", type=Path, default=DEFAULT_PROJECTION_PROBE)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--engine-authority-fd", type=int,
                        help="Supervisor-provided read-only relay for engine strategy queries")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    core_directory = args.core_directory or args.directory
    if not core_directory.is_dir():
        parser.error("--core-directory must be an existing directory")
    provider = ProjectionProvider(str(core_directory.resolve()), str(args.projection_probe.resolve()))
    with ExitStack() as cleanup:
        source = None
        if args.engine_authority_fd is not None:
            if not hasattr(socket, "AF_UNIX"):
                parser.error("--engine-authority-fd requires Unix sockets")
            stream = cleanup.enter_context(socket.socket(
                socket.AF_UNIX, socket.SOCK_STREAM, 0, fileno=args.engine_authority_fd))
            source = SimpleNamespace(authority=EnginePairList(stream))
        _, server = cleanup.enter_context(open_node_web(
            directory=args.directory, ui_path=args.ui, port=args.port, projection=provider,
            command_server=CommandServer(secrets.token_bytes(32)), instance_source=source))
        print("Web control plane: http://127.0.0.1:" + str(server.server_port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
