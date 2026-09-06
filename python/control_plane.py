"""Control-plane command channel (Python side).

Signs ControlCommand envelopes and serves them to the Zig host over a
localhost TCP pull channel. The envelope format is frozen in
src/control_channel.zig; both sides must stay byte-compatible.
"""

import hashlib
import hmac
import socket
import struct
import time

ENVELOPE_VERSION = 1
MAC_LEN = 32
KEY_LEN = 32

# Must match operational.CommandKind declaration order in src/operational.zig.
KIND = {
    "start_recovery": 0,
    "enable_trading": 1,
    "trading_pause": 2,
    "cancel_open_orders": 3,
    "stop_keep_positions": 4,
    "de_risk": 5,
    "resolve_latch": 6,
    "kill_switch": 7,
}

_COMMAND_STRUCT = struct.Struct("<QQQQQQQQBqQQBQQ")


def _u128_parts(value: int) -> tuple[int, int]:
    value = int(value)
    if value < 0 or value >= 1 << 128:
        raise ValueError("u128 out of range")
    return value & 0xFFFFFFFFFFFFFFFF, value >> 64


def _canonical_bytes(command: dict) -> bytes:
    """Encodes one command exactly like the shard control_command codec."""
    ident_lo, ident_hi = _u128_parts(command["command_identity"])
    hash_lo, hash_hi = _u128_parts(command["content_hash"])
    target_lo, target_hi = _u128_parts(command["target_identity"])
    latch_lo, latch_hi = _u128_parts(command.get("referenced_latch_identity", 0))
    warn_lo, warn_hi = _u128_parts(command.get("risk_warning_identity", 0))
    return _COMMAND_STRUCT.pack(
        ident_lo, ident_hi,
        hash_lo, hash_hi,
        target_lo, target_hi,
        command["expected_version"],
        command["expires_at"],
        KIND[command["kind"]],
        command.get("target_position", 0),
        latch_lo, latch_hi,
        1 if command.get("risk_warning_acknowledged") else 0,
        warn_lo, warn_hi,
    )


def content_hash(command: dict) -> int:
    """Deterministic binding over every business field except itself."""
    zeroed = dict(command)
    zeroed["content_hash"] = 0
    digest = hashlib.sha256(_canonical_bytes(zeroed)).digest()
    return int.from_bytes(digest[:16], "little")


def sign_command(command: dict, key: bytes) -> bytes:
    """Returns the full signed envelope bytes for one command."""
    if len(key) != KEY_LEN:
        raise ValueError("channel key must be 32 bytes")
    signed = dict(command)
    signed["content_hash"] = content_hash(command)
    body = _canonical_bytes(signed)
    mac = hmac.new(key, bytes([ENVELOPE_VERSION]) + body, hashlib.sha256).digest()
    return bytes([ENVELOPE_VERSION]) + mac + body


def frame(envelope: bytes) -> bytes:
    return struct.pack("<I", len(envelope)) + envelope


FRAME_TERMINATOR = b"\x00\x00\x00\x00"


class CommandServer:
    """Single-client localhost pull server; each poll drains pending commands."""

    def __init__(self, key: bytes):
        self.key = key
        self._pending: list[bytes] = []
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.bind(("127.0.0.1", 0))
        self._socket.listen(1)
        self.port = self._socket.getsockname()[1]

    def enqueue(self, command: dict) -> None:
        self._pending.append(frame(sign_command(command, self.key)))

    def serve_one_connection(self) -> None:
        conn, _ = self._socket.accept()
        try:
            request = self._recv_exact(conn, 1)
            if request != b"P":
                raise ValueError("unexpected channel request")
            self._drain_into(conn)
        finally:
            conn.close()

    def serve_forever(self) -> None:
        """Accepts sequential pull connections until close().

        No single bad connection may kill the accept loop: the control plane
        outliving any single node poll is an invariant.
        """
        while True:
            try:
                self._serve_once()
            except Exception:
                time.sleep(0.05)

    def _serve_once(self) -> None:
        conn, _ = self._socket.accept()
        try:
            conn.settimeout(5)
            request = self._recv_exact(conn, 1)
            if request != b"P":
                raise ValueError("unexpected channel request")
            self._drain_into(conn)
        finally:
            conn.close()

    def _drain_into(self, conn: socket.socket) -> None:
        import sys as _sys
        print(f"[channel {id(self):x}] draining {len(self._pending)} envelope(s)",
              file=_sys.stderr, flush=True)
        view = memoryview(b"".join(self._pending))
        while view.nbytes > 0:
            sent = conn.send(view)
            view = view[sent:]
        conn.sendall(FRAME_TERMINATOR)
        self._pending.clear()

    def close(self) -> None:
        self._socket.close()

    @staticmethod
    def _recv_exact(conn: socket.socket, count: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < count:
            chunk = conn.recv(count - len(chunks))
            if not chunk:
                raise ConnectionError("channel closed mid-request")
            chunks.extend(chunk)
        return bytes(chunks)

