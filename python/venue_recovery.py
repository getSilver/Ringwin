"""Relay durable Venue recovery between authenticated Linux role connections."""

import struct


def _receive(stream, size):
    result = bytearray()
    while len(result) < size:
        value = stream.recv(size - len(result))
        if not value:
            raise EOFError("Venue recovery role disconnected")
        result.extend(value)
    return result


def recover_market_inputs(engine, market_feed):
    """Submit one source sweep and return its raw barrier and engine status.

    Both connections belong to the controller and have consumed their startup
    status. On transport failure the controller must discard both connections.
    """
    market_feed.sendall(b"U")
    barrier = _receive(market_feed, 8)
    raw_barrier, = struct.unpack("<Q", barrier)
    if raw_barrier == 0:
        # An explicit failure also invalidates previously collected source proofs.
        engine.sendall(b"U" + bytes(32) + struct.pack("<I", 0xFFFFFFFF))
    else:
        source = _receive(market_feed, 24)
        engine.sendall(b"U" + source + barrier)
        while True:
            header = _receive(market_feed, 4)
            size, = struct.unpack("<I", header)
            if size in (0, 0xFFFFFFFF):
                engine.sendall(header)
                break
            if size >= 16 * 1024:
                raise ValueError("oversized Venue recovery frame")
            engine.sendall(header + _receive(market_feed, size))
    status = _receive(engine, 1)
    if status not in (b"R", b"V"):
        raise ValueError("invalid engine recovery status")
    return raw_barrier, bytes(status)
