"""Run the existing authenticated Web control plane with configured public scanning."""
import argparse
from contextlib import ExitStack, contextmanager
import getpass
import json
import os
from pathlib import Path
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


class EngineStrategyAuthority:
    """Use the bounded engine authority relay supplied by the node supervisor."""

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
        operation = value.get("operation")
        mutations = ("approve_pair", "revoke_pair")
        receipts = ("pair_approval_status", "pair_revocation_status")
        strategy_package.require(operation in ("pair_trading_list", "strategy_instances", "pair_authorization_version")
                                 or operation in mutations + receipts,
                                 "engine strategy operation unavailable")
        data = strategy_package.canonical(value)
        strategy_package.require(len(data) <= self.max_frame_bytes, "engine request too large")
        with self.lock:
            try:
                command = b"Q" if operation in mutations else b"P"
                self.stream.sendall(command + struct.pack("<I", len(data)) + data)
                size, = struct.unpack("<I", self.receive(4))
                if not 0 < size <= self.max_frame_bytes:
                    raise OSError("invalid engine response size")
                result = json.loads(self.receive(size))
                if type(result) is not dict:
                    raise OSError("invalid engine response")
                if set(result) == {"error"} and type(result["error"]) is str:
                    error = result["error"]
                elif operation == "strategy_instances":
                    if set(result) != {"instances"} or type(result["instances"]) is not list:
                        raise OSError("invalid engine strategy instances")
                    return result
                elif operation == "pair_trading_list" and set(result) == {"pairs"} and (
                        result["pairs"] is None or type(result["pairs"]) is list):
                    return result
                elif operation == "pair_authorization_version" and set(result) == {"core_version"} and (
                        isinstance(result["core_version"], str) and result["core_version"].isdigit()):
                    return result
                elif operation in mutations + receipts and result.get("status") in (
                        "accepted", "rejected", "unknown") and result.get("identity") == value.get("identity"):
                    if result["status"] == "accepted" and any(
                            type(result.get(field)) is not str or not result[field].isascii()
                            or not result[field].isdigit() or int(result[field]) == 0
                            for field in ("core_version", "barrier")):
                        raise OSError("invalid engine receipt version or barrier")
                    return result
                else:
                    raise OSError("invalid engine response")
            except (OSError, ValueError):
                self.stream.close()
                raise
        raise ValueError(error)

    def instances(self):
        return self.request({"operation": "strategy_instances"})["instances"]


@contextmanager
def open_node_web(*, directory, ui_path, port, projection, command_server, release_manager=None,
                  lifecycle_outbox=None, instance_source=None, engine_strategy_reader=None,
                  engine_strategy_authority=None, engine_strategy_query=None):
    """Open the Web control plane. The node drives committed input via app.instance_manager."""
    if instance_source is not None and instance_source.authority is None:
        raise ValueError("strategy instance access requires node authority")
    if (release_manager is None) != (lifecycle_outbox is None):
        raise ValueError("strategy release management requires a lifecycle outbox")

    with ExitStack() as cleanup:
        cleanup.callback(command_server.close)
        app = ControlPlaneApp(str(directory), command_server, ui_path=str(ui_path),
                              projection_provider=projection, release_manager=release_manager,
                              lifecycle_outbox=lifecycle_outbox, instance_source=instance_source,
                              engine_strategy_reader=engine_strategy_reader,
                              engine_strategy_authority=engine_strategy_authority,
                              engine_strategy_query=engine_strategy_query)
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
                        help="Supervisor-provided relay for engine strategy queries and pair approval changes")
    parser.add_argument("--engine-pair-approval", action="store_true",
                        help="Use a supervisor relay authorized to forward pair approval and revocation frames")
    args = parser.parse_args()
    if args.engine_pair_approval and args.engine_authority_fd is None:
        parser.error("--engine-pair-approval requires --engine-authority-fd")
    args.directory.mkdir(parents=True, exist_ok=True)
    core_directory = args.core_directory or args.directory
    if not core_directory.is_dir():
        parser.error("--core-directory must be an existing directory")
    provider = ProjectionProvider(str(core_directory.resolve()), str(args.projection_probe.resolve()))
    with ExitStack() as cleanup:
        authority = None
        if args.engine_authority_fd is not None:
            if not hasattr(socket, "AF_UNIX"):
                parser.error("--engine-authority-fd requires Unix sockets")
            stream = cleanup.enter_context(socket.socket(
                socket.AF_UNIX, socket.SOCK_STREAM, 0, fileno=args.engine_authority_fd))
            authority = EngineStrategyAuthority(stream)
        _, server = cleanup.enter_context(open_node_web(
            directory=args.directory, ui_path=args.ui, port=args.port, projection=provider,
            command_server=CommandServer(secrets.token_bytes(32)),
            engine_strategy_reader=authority.instances if authority else None,
            engine_strategy_authority=authority if args.engine_pair_approval else None,
            engine_strategy_query=authority.request if authority else None))
        print("Web control plane: http://127.0.0.1:" + str(server.server_port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
